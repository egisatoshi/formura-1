CC = mpicc
CCFLAG = -Wall -std=c99 -O3 -ffast-math -mavx2 -mfma
CCLIBS = -lm
.SUFFIXES:
.PRECIOUS: %.s

diffusion1.c diffusion1.h: diffusion1.fmr diffusion1.yaml
	formura diffusion1.fmr

%.s: %.c diffusion1.h
	$(CC) $(CCFLAG) -S $< -o $@ $(CCLIBS)

%.o: %.s
	$(CC) $(CCFLAG) -c $< -o $@ $(CCLIBS)

main: main.o diffusion1.o
	$(CC) $(CCFLAG) $^ -o $@ $(CCLIBS)

run: main
	mkdir -p data
	./run ./main

clean:
	rm -rf *.o *.s main
