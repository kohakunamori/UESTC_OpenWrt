//go:build linux

package main

import "syscall"

func bindToDevice(raw syscall.RawConn, iface string) error {
	var controlErr error
	err := raw.Control(func(fd uintptr) {
		controlErr = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, iface)
	})
	if err != nil {
		return err
	}
	return controlErr
}
