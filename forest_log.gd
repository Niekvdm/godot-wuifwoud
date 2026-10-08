# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestLog
extends RefCounted
## Where Wuifwoud's log lines go. By default they print (warnings and errors through Godot's own channels); a
## project points `sink` at its own logger once, usually from a feeder. The sink takes (level, message), level one
## of &"debug", &"info", &"warn", &"error". A sink whose object has been freed is ignored. A line raised on
## another thread reaches the sink on the main thread.

## Where the lines go: Callable(level: StringName, message: String); unset, they print.
static var sink: Callable = Callable()


## A debug line.
static func debug(msg: String) -> void:
	_emit(&"debug", msg)


## An info line.
static func info(msg: String) -> void:
	_emit(&"info", msg)


## A warning.
static func warn(msg: String) -> void:
	_emit(&"warn", msg)


## An error.
static func error(msg: String) -> void:
	_emit(&"error", msg)


static func _emit(level: StringName, msg: String) -> void:
	# A placement WORKER can log (an unknown species is first looked up there); a host's logger need not be
	# thread-safe, so a worker's line is delivered on the main thread, at the end of the frame.
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		_emit.call_deferred(level, msg)
		return
	if sink.is_valid():
		sink.call(level, msg)
		return
	match level:
		&"warn":
			push_warning(msg)
		&"error":
			push_error(msg)
		&"info":
			print(msg)
		_:
			print_verbose(msg)
