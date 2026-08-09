/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "AIReasoningiSHHost.h"

int main(void) {
    return ARISHOpenMinisHostRuntimeV1() == 0 ? 1 : 0;
}
