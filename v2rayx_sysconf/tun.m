//
//  tun.m
//  v2rayx_sysconf
//
//  Created by tzmax on 2023/1/20.
//  Copyright © 2023 Project V2Ray. All rights reserved.
//

#import <Foundation/Foundation.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/ioctl.h>

// import CTLIOCGINFO and TUNSIFMODE, from: https://github.com/songgao/water/blob/master/syscalls_darwin.go
#define _IOW(g,n,t) _IOC(IOC_IN, (g), (n), sizeof(t))
#define TUNSIFMODE _IOW('t', 94, int)

// from: sys/sys_domain.h
#define SYSPROTO_CONTROL 2

#define AF_SYS_CONTROL 2

#define UTUN_OPT_IFNAME 2

#define UTUN_CONTROL_NAME "com.apple.net.utun_control"


int createTUN () {
    
    uint32_t ifIndex  = -1;
    int fd;
    int err = 0;
    
    fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return fd;
    
    struct ctl_info info;
    bzero(&info, sizeof (info));
    strncpy(info.ctl_name, UTUN_CONTROL_NAME, MAX_KCTL_NAME);
    
    err = ioctl(fd, CTLIOCGINFO, &info);
    if (err != 0) goto on_error;
    
    struct sockaddr_ctl addr;
    addr.sc_len = sizeof(addr);
    addr.sc_family = AF_SYSTEM;
    addr.ss_sysaddr = AF_SYS_CONTROL;
    addr.sc_id = info.ctl_id;
    addr.sc_unit = ifIndex + 1;
    err = connect(fd, (struct sockaddr *)&addr, sizeof (addr));
    if (err != 0) goto on_error;
    
    char ifname[20];
    socklen_t ifname_len = sizeof(ifname);
    err = getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, ifname, &ifname_len);
    if (err != 0) goto on_error;
    
    err = fcntl(fd, F_SETFL, O_NONBLOCK);
    if (err != 0) goto on_error;

on_error:
  if (err != 0) {
    close(fd);
    return err;
  }

    return fd;
}
