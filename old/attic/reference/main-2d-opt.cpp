#include <algorithm>
#include <cassert>
#include <climits>
#include <cstdlib>
#include <sys/time.h>
#include <iostream>
#include <fstream>
#include <cstdlib>
#include <sstream>

using namespace std;

const int NX=1024;
const int NY=NX;
int T_FINAL;

const int X_MASK = NX-1, Y_MASK=NY-1;

const int NT=16;
const int NTO=NX/NT;
const int NF=NX/4;


double dens_initial[NX][NX];
double dens_final[NX][NX];

double dens_final_pitch[NX][NX];

double yuka[NTO][NTO][1][NT+2][NT+2];

const int N_KABE=NF+NT/2+2;
double yuka_tmp[1][NT+2][NT+2];
double kabe_y[NTO][NTO][N_KABE][2][NT+2];
double kabe_x[NTO][NTO][N_KABE][NT+2][2];

static double second(){
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return double(tv.tv_sec) + 1.e-6*double(tv.tv_usec);
}


void initialize() {
  for (int y=0; y<NY; ++y) {
    for (int x=0; x<NX; ++x) {
      dens_initial[y][x]=(rand()/double(INT_MAX)*2 > 1 ? 1 : 0);
      dens_final[y][x]=424242;
    }
  }
}
void dump(const char* fn) {
  ofstream ofs(fn);
  for (int y=0; y<NY; ++y) {
    for(int x=0;x<NX;++x) {
      ofs << x << " " << y << " " << dens_final[y][x] << endl;
    }
    ofs << endl;
  }
}



inline double stencil_function(double o, double a, double b, double c, double d) {
  return 0.5*o+0.125*(a+b+c+d);
}


double ref_buf[NX][NX];
double ref_buf2[NX][NX];

void compute_reference() {
  for (int y=0;y<NY;++y) {
    for (int x=0;x<NX;++x) {
      ref_buf[y][x]=dens_initial[y][x];
    }
  }

  for (int t=1; t <=T_FINAL; ++t) {
    for (int y=0;y<NY;++y) {
      for (int x=0;x<NX;++x) {
        ref_buf2[y][x]=stencil_function
          (ref_buf[y][x],
           ref_buf[(y-1)&Y_MASK][x],
           ref_buf[(y+1)&Y_MASK][x],
           ref_buf[y][(x-1)&X_MASK],
           ref_buf[y][(x+1)&X_MASK]
           );
      }
    }
    swap(ref_buf, ref_buf2);
  }
  for (int y=0;y<NY;++y) {
    for (int x=0;x<NX;++x) {
      dens_final[y][x] = ref_buf[y][x];
    }
  }
}



double work[N_KABE][NT+2][NT+2];

template <bool near_initial, bool near_final>
void pitch_kernel
(int t_orig, int y_orig, int x_orig,
 double yuka_in[1][NT+2][NT+2], double kabe_y_in[N_KABE][2][NT+2], double kabe_x_in[N_KABE][NT+2][2],
 double yuka_out[1][NT+2][NT+2], double kabe_y_out[N_KABE][2][NT+2], double kabe_x_out[N_KABE][NT+2][2])
{
  for(int t=0; t<NF+NT/4+2;++t) {
    for(int y=0; y<NT+2; ++y) {
      work[t][y][0] = kabe_x_in[t+NT/4][y][0];
      work[t][y][1] = kabe_x_in[t+NT/4][y][1];
    }
    for(int x=0; x<NT+2; ++x) {
      work[t][0][x] = kabe_y_in[t+NT/4][0][x];
      work[t][1][x] = kabe_y_in[t+NT/4][1][x];
    }
  }

  // iter 1
  const int t_boundary_1 = NT/2+2;
  const int t_boundary_2 = NF+2;
  for(int t=1; t<t_boundary_1;++t) {
    for(int y=2; y<NT+2; ++y) {
      for(int x=2; x<NT+2; ++x) {
        int t_k=t, y_k = y-t, x_k = x-t;
        int t_dash = (2*t_k-x_k-y_k)>>2;
        const bool in_region = t_dash >=0 && t_dash < NF+1;

        if (in_region) {
          double ret=work[t][y][x];
          if (t_k + t_orig == 0 && near_initial) {
            ret = dens_initial[(y_k+y_orig) & Y_MASK][(x_k+x_orig) & X_MASK];
          } else if (t_dash == 0) {
            ret = yuka_in[0][y][x];
          } else if (t+t_orig>0 && y>=2 && x>=2) {
            asm volatile("#kernel");
            ret = stencil_function(work[t-1][y-1][x-1],work[t-1][y-2][x-1],work[t-1][y][x-1],work[t-1][y-1][x-2],work[t-1][y-1][x]);
          }

          work[t][y][x] = ret;

          if (t_k + t_orig == T_FINAL && near_final) {
            dens_final[(y_k+y_orig) & Y_MASK][(x_k+x_orig) & X_MASK] = ret;
          }
        }
      }
    }
  }

  // iter 2
  for(int t=t_boundary_1; t<t_boundary_2;++t) {
    for(int y=2; y<NT+2; ++y) {
      for(int x=2; x<NT+2; ++x) {
        int t_k=t, y_k = y-t, x_k = x-t;

        double ret=work[t][y][x];
        if (t_k + t_orig == 0 && near_initial) {
          ret = dens_initial[(y_k+y_orig) & Y_MASK][(x_k+x_orig) & X_MASK];
        } else if (t+t_orig>0 && y>=2 && x>=2) {
          asm volatile("#kernel");
          ret = stencil_function(work[t-1][y-1][x-1],work[t-1][y-2][x-1],work[t-1][y][x-1],work[t-1][y-1][x-2],work[t-1][y-1][x]);
        }
        work[t][y][x] = ret;
        if (t_k + t_orig == T_FINAL && near_final) {
            dens_final[(y_k+y_orig) & Y_MASK][(x_k+x_orig) & X_MASK] = ret;
        }
      }
    }
  }


  // iter 3
  for(int t=t_boundary_2; t<NF+NT/2+2;++t) {
    for(int y=2; y<NT+2; ++y) {
      for(int x=2; x<NT+2; ++x) {
        int t_k=t, y_k = y-t, x_k = x-t;
        int t_dash = (2*t_k-x_k-y_k)>>2;
        const bool in_region = t_dash >=0 && t_dash < NF+1;

        if (in_region) {
          double ret=work[t][y][x];
          if (t_k + t_orig == 0 && near_initial) {
            ret = dens_initial[(y_k+y_orig) & Y_MASK][(x_k+x_orig) & X_MASK];
          } else if (t+t_orig>0 && y>=2 && x>=2) {
            asm volatile("#kernel");
            ret = stencil_function(work[t-1][y-1][x-1],work[t-1][y-2][x-1],work[t-1][y][x-1],work[t-1][y-1][x-2],work[t-1][y-1][x]);
          }

          work[t][y][x] = ret;

          if (t_dash == NF && t >=NF+2) {
            yuka_out[0][y][x] = ret;
          }
          if (t_k + t_orig == T_FINAL && near_final) {
            dens_final[(y_k+y_orig) & Y_MASK][(x_k+x_orig) & X_MASK] = ret;
          }
        }
      }
    }
  }


  for(int t=0; t<NF+NT/2+2;++t) {
    for(int x=0; x<NT+2; ++x) {
      kabe_y_out[t][0][x] = work[t][NT+0][x];
      kabe_y_out[t][1][x] = work[t][NT+1][x];
    }
    for(int y=0; y<NT+2; ++y) {
      kabe_x_out[t][y][0] = work[t][y][NT+0];
      kabe_x_out[t][y][1] = work[t][y][NT+1];
    }
  }


}

void compute_pitch(){
  for(int t_orig=-NX; t_orig <= T_FINAL; t_orig+=NF) {
    bool near_initial = t_orig < 0;
    bool near_final   = t_orig >= T_FINAL-NX;
    int y_orig = -t_orig;
    int x_orig = -t_orig;
    for (int yo=0;yo<NTO;++yo) {
      for (int xo=0;xo<NTO;++xo) {
        int dy = yo*NT, dx = xo*NT;
        if(near_initial && near_final) {
          pitch_kernel<true, true>
            (t_orig+(dx+dy)/4,
             y_orig+(3*dy-dx)/4,
             x_orig+(3*dx-dy)/4,
             yuka[yo][xo],kabe_y[yo][xo],kabe_x[yo][xo],
             yuka_tmp,kabe_y[(yo+1)%NTO][xo],kabe_x[yo][(xo+1)%NTO]);
        }else if(near_initial) {
          pitch_kernel<true, false>
            (t_orig+(dx+dy)/4,
             y_orig+(3*dy-dx)/4,
             x_orig+(3*dx-dy)/4,
             yuka[yo][xo],kabe_y[yo][xo],kabe_x[yo][xo],
             yuka_tmp,kabe_y[(yo+1)%NTO][xo],kabe_x[yo][(xo+1)%NTO]);
        }else  if(near_final) {
          pitch_kernel<false, true >
            (t_orig+(dx+dy)/4,
             y_orig+(3*dy-dx)/4,
             x_orig+(3*dx-dy)/4,
             yuka[yo][xo],kabe_y[yo][xo],kabe_x[yo][xo],
             yuka_tmp,kabe_y[(yo+1)%NTO][xo],kabe_x[yo][(xo+1)%NTO]);
        }else {
          pitch_kernel<false, false>
            (t_orig+(dx+dy)/4,
             y_orig+(3*dy-dx)/4,
             x_orig+(3*dx-dy)/4,
             yuka[yo][xo],kabe_y[yo][xo],kabe_x[yo][xo],
             yuka_tmp,kabe_y[(yo+1)%NTO][xo],kabe_x[yo][(xo+1)%NTO]);
        }
        swap(yuka[yo][xo], yuka_tmp);
      }
    }
  }
}

int main ()
{
  double n_flop[2], wct_pitch[2], wct_ref[2];

  for(int part=0; part<2; ++part) {
    T_FINAL = NX*(3+part);
    initialize();
    n_flop[part]=6.0*NX*NX*double(T_FINAL);
    double t1 = second();
    compute_pitch();
    double t2 = second();
    cout << "PiTCH: " << n_flop[part] << " flop " << (t2-t1) << " second" << endl;
    wct_pitch[part] = t2-t1;

    swap(dens_final, dens_final_pitch);

    double t3 = second();
    compute_reference();
    double t4 = second();
    cout << "Ref: " << n_flop[part] << " flop " << (t4-t3) << " second" << endl;
    wct_ref[part] = t4-t3;
    for (int y=0;y<NY;++y) {
      for (int x=0;x<NX;++x){
        assert(dens_final[y][x]==dens_final_pitch[y][x]);
      }
    }
  }

  cerr << "PiTCH: " << (n_flop[1]-n_flop[0])/(wct_pitch[1]-wct_pitch[0]) << " flop/s " << endl;
  cerr << "Ref: " << (n_flop[1]-n_flop[0])/(wct_ref[1]-wct_ref[0]) << " flop/s " << endl;
}
