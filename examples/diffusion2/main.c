#include <stdio.h>
#include <math.h>
#include <mpi.h>
#include "diffusion2.h"

#define T_MAX 100

double gauss(double x, double y, double x0, double y0) {
  return exp(-pow((x-x0)/(5*dx),2.0)-pow((y-y0)/(5*dy),2.0));
}

// 初期条件の設定
void setup(Formura_Navi n) {
  double x0 = n.length_x/2.0;
  double y0 = n.length_y/2.0;
  for(int ix = n.lower_x; ix < n.upper_x; ++ix) {
    double x = to_pos_x(ix,n);
    for(int iy = n.lower_y; iy < n.upper_y; ++iy) {
      double y = to_pos_y(iy,n);
      q[ix][iy] = gauss(x,y,x0,y0);
    }
  }
}

void writeData(Formura_Navi n) {
  char fn[256];
  sprintf(fn, "data/%d_%d.dat", n.time_step, n.my_rank);
  FILE *fp = fopen(fn, "w");
  for(int ix = n.lower_x; ix < n.upper_x; ix++) {
    double x = to_pos_x(ix,n);
    for(int iy = n.lower_y; iy < n.upper_y; iy++) {
      double y = to_pos_y(iy,n);
      fprintf(fp, "%f %f %f\n", x, y, q[ix][iy]);
    }
    fprintf(fp, "\n");
  }
  fclose(fp);
  printf("Write: %s\n", fn);
}

int main(int argc, char **argv) {
  MPI_Init(&argc,&argv);

  Formura_Navi n;
  Formura_Init(&n, MPI_COMM_WORLD);
  setup(n);

  writeData(n);
  while(n.time_step < T_MAX) {
    Formura_Forward(&n);
    writeData(n);
  }

  printf("NX = %d\n", NX);
  printf("MX = %d\n", MX);
  printf("NT = %d\n", NT);
  printf("DX = %d\n", DX);
  printf("LX = %d\n", LX);
  MPI_Finalize();
  return 0;
}
