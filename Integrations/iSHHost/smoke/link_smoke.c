#include "AIReasoningiSHHost.h"

int main(void) {
    return ARISHOpenMinisHostRuntimeV1() == 0 ? 1 : 0;
}
