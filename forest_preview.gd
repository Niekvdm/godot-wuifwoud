# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The editor preview's switch: the Forest menu sets it and keeps it in the project's editor
## metadata; every forest in the editor reads it each frame. Never read in the game.

## Whether the editor draws its forests.
static var visible := true
