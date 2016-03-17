{-# LANGUAGE ConstraintKinds, ImplicitParams, LambdaCase, MultiWayIf, TemplateHaskell #-}

module Main where

import           Cases (snakify)
import           Control.Concurrent
import qualified Control.Exception as C
import           Control.Lens
import           Control.Monad.State
import           Data.Aeson.TH
import qualified Data.ByteString as BS
import           Data.Foldable
import qualified Data.HashMap.Strict as HM
import           Data.List (isPrefixOf, sort, intercalate)
import qualified Data.Map as M
import           Data.Maybe
import           Data.Time
import qualified Data.Yaml as Y
import qualified Data.Yaml.Pretty as Y
import qualified Data.Text as T
import qualified Data.Text.Lens as T (packed)
import           System.Directory
import           System.Exit
import           System.FilePath ((</>))
import           System.FilePath.Lens
import           System.IO
import           System.IO.Temp
import           System.IO.Unsafe
import           System.Process
import           Text.Printf
import           Formura.NumericalConfig

----------------------------------------------------------------
-- External Functions Utilities
----------------------------------------------------------------

cmd :: String -> IO ExitCode
cmd str = do
  hPutStrLn stderr str
  system str

-- copy remote file/local file/url from one another
superCopy :: FilePath -> FilePath -> IO ()
superCopy src dest = do
  let isUrl = or [x `isPrefixOf` src | x <- ["http://", "https://", "ftp://"]]
      go :: (String -> IO ()) -> IO ()
      go k
        | isUrl = withSystemTempFile "tmp" $ \fn h -> do
            hClose h
            cmd $ "wget " ++ src ++ " -O " ++ fn
            k fn
        | otherwise = k src
  go $ \fn -> do
    cmd $ unwords ["scp -r ", fn, dest]
    return ()

superDoesFileExist :: FilePath -> IO Bool
superDoesFileExist fn = do
  let (host,b) = break (==':') fn
  case b of
    "" -> doesFileExist fn
    (_:path) -> do
      xc <- cmd $ "ssh " ++ host ++ " test -e " ++ "'" ++ path ++ "'"
      case xc of
        ExitSuccess -> return True
        _ -> return False


writeYaml :: Y.ToJSON a => FilePath -> a -> IO ()
writeYaml fn obj = BS.writeFile fn $ Y.encodePretty (Y.setConfCompare compare Y.defConfig) obj

readYaml :: Y.FromJSON a => FilePath -> IO (Maybe a)
readYaml fn = do
  Y.decodeFileEither fn >>= \case
    Left msg -> do
      hPutStrLn stderr $ "When reading " ++ fn ++ "\n" ++ Y.prettyPrintParseException msg
      return Nothing
    Right x -> return $ Just x

readYamlDef :: (Y.ToJSON a, Y.FromJSON a) => a -> FilePath -> IO (Maybe a)
readYamlDef def fn = do
  Y.decodeFileEither fn >>= \case
    Left msg -> do
      hPutStrLn stderr $ "When reading " ++ fn ++ "\n" ++ Y.prettyPrintParseException msg
      return Nothing
    Right v -> do
      let v2 :: Y.Value
          v2 = unionValue v (Y.toJSON def)
      case (Y.decodeEither' $ Y.encode v2) of
        Left msg -> do
          hPutStrLn stderr $ "When merginf " ++ fn ++ "\n" ++ Y.prettyPrintParseException msg
          return Nothing
        Right x -> return $ Just x

  where
    unionValue :: Y.Value -> Y.Value -> Y.Value
    unionValue (Y.Object hm1) (Y.Object hm2) = Y.Object $ HM.unionWith unionValue hm1 hm2
    unionValue a _ = a

-- Object !Object
-- Array !Array
-- String !Text
-- Number !Scientific
-- Bool !Bool
-- Null


readCmd :: String -> IO String
readCmd str = interactCmd str ""

interactCmd
    :: String                   -- ^ shell command to run
    -> String                   -- ^ standard input
    -> IO String                -- ^ stdout + stderr
interactCmd cmdstr input = do
    (Just inh, Just outh, _, pid) <-
        createProcess (shell cmdstr){ std_in  = CreatePipe,
                                      std_out = CreatePipe,
                                      std_err = Inherit }

    -- fork off a thread to start consuming the output
    output  <- hGetContents outh
    outMVar <- newEmptyMVar
    forkIO $ C.evaluate (length output) >> putMVar outMVar ()

    -- now write and flush any input
    when (not (null input)) $ do hPutStr inh input; hFlush inh
    hClose inh -- done with stdin

    -- wait on the output
    takeMVar outMVar
    hClose outh

    -- wait on the process
    ex <- waitForProcess pid

    case ex of
     ExitSuccess   -> return output
     ExitFailure r ->
      error ("readSystem: " ++ cmdstr ++ " (exit " ++ show r ++ ")")



----------------------------------------------------------------
-- Incubator Datatypes
----------------------------------------------------------------

type WaitList = [([FilePath], Action)]

data Action = Codegen
            | Compile
            | Benchmark
            | Visualize
            | Wait Action WaitList -- Wait for certain files to appear, then transit to next action
            | Done
            | Failed Action
              deriving (Eq, Ord, Show, Read)

deriveJSON defaultOptions ''Action


data QBConfig =
  QBConfig
  { _qbHostName :: String
  , _qbWorkDir :: String
  , _qbLabNotePath :: String
  , _qbRemoteLabNotePath :: String
  }

makeClassy ''QBConfig

$(deriveJSON (let toSnake = T.packed %~ snakify in
               defaultOptions{fieldLabelModifier = toSnake . drop 3,
                              constructorTagModifier = toSnake,
                              omitNothingFields = True})
  ''QBConfig)


qbConfigFilePath :: FilePath
qbConfigFilePath = ".qb/config"

qbDefaultConfig = QBConfig
  { _qbHostName = "K"
  , _qbWorkDir = ".qb/"
  , _qbLabNotePath = "/home/nushio/hub/3d-mhd/individuals"
  , _qbRemoteLabNotePath = "/volume81/data/ra000008/nushio/individuals"}

type WithQBConfig = ?qbc :: QBConfig

data Individual =
  Individual
  { _idvFormuraVersion :: String
  , _idvFmrSourcecodeURL :: String
  , _idvCppSourcecodeURL :: String
  , _idvNumericalConfig :: NumericalConfig
  , _idvCompilerFlags :: [String]
  } deriving (Eq, Ord, Read, Show)

makeClassy ''Individual

$(deriveJSON (let toSnake = T.packed %~ snakify in
               defaultOptions{fieldLabelModifier = toSnake . drop 4,
                              constructorTagModifier = toSnake,
                              omitNothingFields = True})
  ''Individual)

defaultIndividual :: Individual
defaultIndividual = Individual
  { _idvFormuraVersion = "2f8eb9c50669914e17ba24105380d0f4f631ea59"
  , _idvFmrSourcecodeURL = "/home/nushio/hub/formura/examples/3d-mhd.fmr"
  , _idvCppSourcecodeURL = "/home/nushio/hub/formura/examples/3d-mhd-main-prof.cpp"
  , _idvNumericalConfig = unsafePerformIO $ fromJust <$> readYaml "/home/nushio/hub/formura/examples/3d-mhd.yaml"
  , _idvCompilerFlags = ["-O3", "-Kfast,parallel", "-Kocl", "-Klib", "-Koptmsg=2", "-Karray_private", "-Kinstance=8", "-Kdynamic_iteration", "-Kloop_fission", "-Kloop_part_parallel", "-Kloop_part_simd", "-Keval", "-Kreduction", "-Ksimd=2"]
  }


data Experiment =
  Experiment
  { _xpAction :: Action
  , _xpIndividualFilePath :: FilePath
  , _xpExperimentFilePath :: FilePath
  , _xpLocalWorkDir :: String
  , _xpLocalCodeDir :: String
  , _xpRemoteWorkDir :: String
  , _xpRemoteExecPath :: String
  , _xpRemoteOutputPath :: String
  , _xpImagePath :: String
  , _xpTimeStamps :: [(UTCTime,UTCTime,Action)]
  } deriving (Eq, Ord, Read, Show)

makeClassy ''Experiment

$(deriveJSON (let toSnake = T.packed %~ snakify in
               defaultOptions{fieldLabelModifier = toSnake . drop 3,
                              constructorTagModifier = toSnake,
                              omitNothingFields = True})
  ''Experiment)

defaultExperiment :: Experiment
defaultExperiment = Experiment
  { _xpAction = Codegen
  , _xpIndividualFilePath = ""
  , _xpExperimentFilePath = ""
  , _xpLocalWorkDir = ""
  , _xpLocalCodeDir = ""
  , _xpRemoteWorkDir = ""
  , _xpRemoteExecPath = ""
  , _xpRemoteOutputPath = ""
  , _xpImagePath = ""
  , _xpTimeStamps = []
  }


data IndExp = IndExp Individual Experiment
            deriving (Eq, Ord, Show, Read)

instance HasIndividual IndExp where
  individual f (IndExp i x) = (\i -> IndExp i x) <$> f i
instance HasExperiment IndExp where
  experiment f (IndExp i x) = (\x -> IndExp i x) <$> f x
instance HasNumericalConfig IndExp where
  numericalConfig = individual . idvNumericalConfig



data IncubatorState =
  IncubatorState
  { _qbConfig :: QBConfig
  , _qbIndividual :: Individual}

makeClassy ''IncubatorState

instance HasQBConfig IncubatorState where
  qBConfig = qbConfig

instance HasIndividual IncubatorState where
  individual = qbIndividual


----------------------------------------------------------------
-- Incubator functions
----------------------------------------------------------------

remoteCmd :: WithQBConfig => String -> IO ExitCode
remoteCmd str = do
  let host = ?qbc ^. qbHostName
  cmd $ "ssh " ++ host ++ " '(" ++ str ++ ")'"


readIndExp :: FilePath -> IO (Maybe IndExp)
readIndExp fn = do
  readYamlDef defaultIndividual fn >>= \case
    Nothing -> return Nothing
    Just idv0 -> do
      let xpfn = fn & extension .~ "exp"
      xp0 <- maybe defaultExperiment id <$> readYamlDef defaultExperiment xpfn
      let xp1 = xp0
            { _xpLocalWorkDir = fn ^. directory
            , _xpIndividualFilePath = fn
            , _xpExperimentFilePath = xpfn
            }
      return $ Just $ IndExp idv0 xp1

writeIndExp :: IndExp -> IO ()
writeIndExp it = do
  -- Do not alter individual:
  -- writeYaml (it ^. xpIndividualFilePath) (it ^. individual)
  writeYaml (it ^. xpExperimentFilePath) (it ^. experiment)

getCodegen :: WithQBConfig => String -> IO FilePath
getCodegen gitKey = do
  absPath <- getCurrentDirectory
  let fn = cpath </>("formura-" ++ gitKey)
      cpath = absPath </> (?qbc ^. qbWorkDir) </> "compilers"
  cmd $ "mkdir -p " ++ cpath
  doesFileExist fn >>= \case
    True -> return fn
    False -> do
      withSystemTempDirectory "qb-codegen" $ \dir -> do
        withCurrentDirectory dir $ do
          putStrLn dir
          cmd $ "git clone /home/nushio/hub/formura ."
          cmd $ "git checkout " ++ gitKey
          cmd $ "stack install --local-bin-path ./bin"
          cmd $ "cp ./bin/formura " ++ fn
      return fn

codegen :: WithQBConfig => IndExp -> IO IndExp
codegen it = do
  let labNote = ?qbc ^. qbLabNotePath
      codeDir = it ^. xpLocalWorkDir </> "src"
  cmd $ "mkdir -p " ++ codeDir
  codegenFn <- getCodegen $ it ^. idvFormuraVersion
  withCurrentDirectory codeDir $ do
    cmd $ "rm *.c *.cpp *.h *.out"
    superCopy (it ^. idvFmrSourcecodeURL) "3d-mhd.fmr"
    superCopy (it ^. idvCppSourcecodeURL) "3d-mhd-main.cpp"
    writeYaml "3d-mhd.yaml" $ it ^. idvNumericalConfig
    forM_ ["3d-mhd.fmr", "3d-mhd.yaml", "3d-mhd-main.cpp"] $ \fn -> do
      cmd $ "git add " ++ fn

    cmd $ codegenFn ++ " 3d-mhd.fmr"
    foundFiles <- fmap (sort . lines) $ readCmd $ "find ."
    let csrcFiles =
          [fn | fn <- foundFiles, fn ^. extension == ".cpp"] ++
          [fn | fn <- foundFiles, fn ^. extension == ".c"]
        objFiles = [fn & extension .~ "o"  |fn <- csrcFiles]

        c2oCmd fn = unlines
          [ (fn & extension .~ "o") ++ ": " ++ fn
          , "\t$(CC) -c $^ -o $@ 2> $@.optmsg"]

    writeFile "Makefile" $ unlines
      [ "all: a.out"
      , "CC=mpiFCCpx " ++ unwords (it ^. idvCompilerFlags)
      , "OBJS=" ++ unwords objFiles
      , "a.out: $(OBJS)"
      , "\t$(CC) $(OBJS) -o a.out"
      , unlines $ map c2oCmd csrcFiles]
    writeFile "make.sh" $ unlines
      [ "rm *.o ./a.out make.done"
      , "make -j8"
      , "make -j4"
      , "make -j2"
      , "make"
      , "touch make.done"]
    cmd "chmod 755 make.sh"
  return $ it
    & xpAction .~ Compile
    & xpLocalCodeDir .~ codeDir

compile :: WithQBConfig => IndExp -> IO IndExp
compile it = do
  let localWD = it ^. xpLocalWorkDir
      localLN  = ?qbc ^. qbLabNotePath
      remoteLN = ?qbc ^. qbRemoteLabNotePath
      host = ?qbc ^. qbHostName
  let srcdir = it ^. xpLocalCodeDir
  let remotedir = srcdir & T.packed %~ T.replace (T.pack localLN) (T.pack remoteLN)
  remoteCmd $ "mkdir -p " ++ remotedir
  cmd $ "rsync -avz " ++ (srcdir++"/") ++ " " ++ (?qbc^.qbHostName++":"++remotedir++"/")
  remoteCmd $ "cd " ++ remotedir ++ ";nohup ./make.sh < /dev/null > make.stdout 2> make.stderr &"

  return $ it
    & xpAction .~ Wait Compile
    [ ([host ++ ":" ++ remotedir ++ "/a.out"], Benchmark)
    , ([host ++ ":" ++ remotedir ++ "/make.done"], Failed Compile)]

benchmark :: WithQBConfig => IndExp -> IO IndExp
benchmark it = do
  let labNote = ?qbc ^. qbLabNotePath
      exeDir = it ^. xpLocalWorkDir
      mpiSize :: Int
      mpiSize = product $ it ^. ncMPIGridShape

      mpiNodeShape :: String
      mpiNodeShape = intercalate "x" $ map show $ reverse $ toList $ it ^. ncMPIGridShape
  let
      localLN  = ?qbc ^. qbLabNotePath
      remoteLN = ?qbc ^. qbRemoteLabNotePath
      host = ?qbc ^. qbHostName
  let remotedir = exeDir & T.packed %~ T.replace (T.pack localLN) (T.pack remoteLN)

  withCurrentDirectory exeDir $ do
    writeFile "submit.sh" $ unlines
      [ "#!/bin/sh -x"
      , printf "#PJM --rsc-list \"node=%s\""mpiNodeShape
      , printf "#PJM --mpi \"shape=%s\""mpiNodeShape
      , ""
      , "#time limit"
      , "#PJM --name \"autobenchmark\""
      , "#PJM --rsc-list \"elapse=12:00:00\""
      , "#PJM --rsc-list \"rscgrp=small\""
      , "#PJM --mpi \"use-rankdir\""
      , "#PJM --stg-transfiles all"
      , ""
      , "# stage in  a.out."
      , "#PJM --stgin \"./src/a.out %r:./a.out\""
      , "#PJM --stgout \"%r:./out/* ./out/out-%r/\""
      , "#PJM --stgout \"%r:./prof-ip/* ./out/prof-ip-%r/\""
      , "#PJM --stgout \"%r:./prof-01/* ./out/prof-01-%r/\""
      , "#PJM --stgout \"%r:./prof-02/* ./out/prof-02-%r/\""
      , "#PJM --stgout \"%r:./prof-03/* ./out/prof-03-%r/\""
      , "#PJM --stgout \"%r:./prof-04/* ./out/prof-04-%r/\""
      , "#PJM --stgout \"%r:./prof-05/* ./out/prof-05-%r/\""
      , "#PJM --stgout \"%r:./prof-06/* ./out/prof-06-%r/\""
      , "#PJM --stgout \"%r:./prof-07/* ./out/prof-07-%r/\""
      , ""
      , "#statistics output"
      , "#PJM -s"
      , ""
      , "# config environmental variables"
      , ". /work/system/Env_base"
      , "mpiexec /work/system/bin/msh \"mkdir ./out\""
      , ""
      , printf "fipp -m 30000 -C -d prof-ip -Icall,hwm mpirun -n %d ./a.out" mpiSize
      , printf "fapp -C -d prof-01 -Hpa=1 mpirun -n %d ./a.out" mpiSize
      , printf "fapp -C -d prof-02 -Hpa=2 mpirun -n %d ./a.out" mpiSize
      , printf "fapp -C -d prof-03 -Hpa=3 mpirun -n %d ./a.out" mpiSize
      , printf "fapp -C -d prof-04 -Hpa=4 mpirun -n %d ./a.out" mpiSize
      , printf "fapp -C -d prof-05 -Hpa=5 mpirun -n %d ./a.out" mpiSize
      , printf "fapp -C -d prof-06 -Hpa=6 mpirun -n %d ./a.out" mpiSize
      , printf "fapp -C -d prof-07 -Hpa=7 mpirun -n %d ./a.out" mpiSize
      ]
    cmd $ "chmod 755 " ++ "submit.sh"
  cmd $ "rsync -avz " ++ (exeDir ++"/") ++ " " ++ (?qbc^.qbHostName++":"++remotedir++"/")
  remoteCmd $ "cd " ++ remotedir ++ ";ksub submit.sh"

  let resultFiles = [kpath ++ pat | pat <- ["autobenchmark.i*", "autobenchmark.s*"]]
      kpath = ?qbc^.qbHostName++":"++remotedir++"/"

  return $ it
    & xpAction .~ Wait Benchmark
    [(resultFiles,Visualize)]
  -- TODO: you can map kjobid and job_id via kstat.


visualize :: WithQBConfig => IndExp -> IO IndExp
visualize it = do
  let
      exeDir = it ^. xpLocalWorkDir
      localLN  = ?qbc ^. qbLabNotePath
      remoteLN = ?qbc ^. qbRemoteLabNotePath
      host = ?qbc ^. qbHostName
  let remotedir = exeDir & T.packed %~ T.replace (T.pack localLN) (T.pack remoteLN)
  withCurrentDirectory exeDir $ do
    writeFile "postprocess.sh" $ unlines
      [ printf "fipppx -A -p all -Icpu,balance,call,hwm,src -d out/prof-ip* > out/output_prof_ip.txt"
      , printf "fipppx -A -p all -Icpu,call,hwm -tcsv -d out/prof-ip* > out/output_prof_ip.csv"
      , printf "fapppx -A -p all -l0 -tcsv -Hpa -d out/prof-01-* -o out/output_prof_1.csv"
      , printf "fapppx -A -p all -l0 -tcsv -Hpa -d out/prof-02-* -o out/output_prof_2.csv"
      , printf "fapppx -A -p all -l0 -tcsv -Hpa -d out/prof-03-* -o out/output_prof_3.csv"
      , printf "fapppx -A -p all -l0 -tcsv -Hpa -d out/prof-04-* -o out/output_prof_4.csv"
      , printf "fapppx -A -p all -l0 -tcsv -Hpa -d out/prof-05-* -o out/output_prof_5.csv"
      , printf "fapppx -A -p all -l0 -tcsv -Hpa -d out/prof-06-* -o out/output_prof_6.csv"
      , printf "fapppx -A -p all -l0 -tcsv -Hpa -d out/prof-07-* -o out/output_prof_7.csv"
      ]
    cmd $ "chmod 755 " ++ "postprocess.sh"
  cmd $ "rsync -avz " ++ (exeDir ++"/") ++ " " ++ (?qbc^.qbHostName++":"++remotedir++"/")
  remoteCmd $ "cd " ++ remotedir ++ ";./postprocess.sh"
  cmd $ "rsync -avz " ++ (?qbc^.qbHostName++":"++remotedir++"/out/") ++ " " ++ (exeDir ++"/out/")
  return $ it
    & xpAction .~ Done

waits :: WaitList -> IndExp -> IO IndExp
waits [] it = return it
waits ((fs,a):ws) it = do
  es <- mapM superDoesFileExist fs
  if and es then return $ it & xpAction .~ a
    else waits ws it


main :: IO ()
main = do
  x <- doesFileExist qbConfigFilePath
  if not x then mainInit else mainServer

mainInit :: IO ()
mainInit = do
  cmd "mkdir -p .qb"
  writeYaml qbConfigFilePath qbDefaultConfig

mainServer :: IO ()
mainServer = do
  putStrLn "Qppy!"
  writeYaml "izanagi.idv" defaultIndividual
  Just qbc0 <- readYaml qbConfigFilePath
  let ?qbc = qbc0 :: QBConfig
  let noteDir = ?qbc ^. qbLabNotePath
  withCurrentDirectory noteDir $
    cmd "git pull"
  findIdvs <- readCmd $ "find " ++ noteDir ++ " -name '*.idv'"
  let idvFns = sort $ lines findIdvs

  idxps <- catMaybes <$> mapM readIndExp idvFns

  mapM_ proceed idxps

  return ()

proceed :: WithQBConfig => IndExp -> IO ()
proceed it = do
  putStrLn $ "## "++ it ^. xpExperimentFilePath
  t_begin <- getCurrentTime
  newIt <- case it ^. xpAction of
    Codegen -> codegen it
    Compile -> compile it
    Benchmark -> benchmark it
    Visualize -> visualize it
    Wait _ waitlist -> do
      ret <- waits waitlist it
      case ret ^. xpAction of
        Failed _ -> waits waitlist it -- Double check before choosing to fail.
        _ -> return ret
    Done -> return it
    x -> do
      hPutStrLn stderr $ "Unimplemented Action: " ++ show x
      return it
  t_end <- getCurrentTime
  let newIt2 = newIt & xpTimeStamps %~ insertTimeStamp (t_begin, t_end, it ^. xpAction)

  writeIndExp $ newIt2
  print (newIt2 ^. xpAction)

  where
    insertTimeStamp ts [] = [ts]
    insertTimeStamp ts@(_,te,a1) tss@((tb,_,a2):tstail)
      | a1 == a2  = (tb,te,a1):tstail
      | otherwise = ts:tss
{- note: to submit interactive job on greatwave:

 pjsub --interact -L node=4 -L elapse=2:00:00 -L rscunit=gwmpc

-}
