//go:build !linux

package main

import "syscall"

func bindToDevice(raw syscall.RawConn, iface string) error {
	return nil
}
