/* SPDX-License-Identifier: GPL-3.0-or-later */

#ifndef AIReasoningiSHTestSupport_h
#define AIReasoningiSHTestSupport_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool ARISHFixtureInstall(void);
void ARISHFixtureReset(void);
void ARISHFixtureComplete(int32_t exit_code);
size_t ARISHFixtureWrittenByteCount(void);
size_t ARISHFixtureCountOfByte(uint8_t byte);
size_t ARISHFixtureSignalCount(void);
int32_t ARISHFixtureSignalAtIndex(size_t index);
const char *ARISHFixtureWorkspaceHostPath(void);
const char *ARISHFixtureWorkspaceGuestPath(void);
int ARISHFixtureWorkspaceReadOnly(void);

#endif
