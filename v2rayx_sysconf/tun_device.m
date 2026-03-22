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
#include <sys/uio.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <net/if.h>
#include <arpa/inet.h>

#define TUN_GATEWAY "169.254.10.1"
#define TUN_PREFIX 30

#define SIOCAIFADDR6 0x8040691A
#define IN6_IFF_NODAD 0x0020
#define ND6_INFINITE_LIFETIME 0xFFFFFFFF

// import CTLIOCGINFO and TUNSIFMODE, from: https://github.com/songgao/water/blob/master/syscalls_darwin.go
#define _IOW(g,n,t) _IOC(IOC_IN, (g), (n), sizeof(t))
#define TUNSIFMODE _IOW('t', 94, int)

// from: sys/sys_domain.h
#define SYSPROTO_CONTROL 2

#define AF_SYS_CONTROL 2

#define UTUN_OPT_IFNAME 2

#define UTUN_CONTROL_NAME "com.apple.net.utun_control"

int createTUNWithName(NSString* preferredName, NSString** actualNameOut);
BOOL sendFileDescriptor(int socketFD, int fileDescriptor, NSString* payload);

typedef struct {
    char ifra_name[IFNAMSIZ];
    struct sockaddr_in ifra_addr;
    struct sockaddr_in ifra_dstaddr;
    struct sockaddr_in ifra_mask;
} ifAliasReq4;

typedef struct {
    char ifra_name[IFNAMSIZ];
    struct sockaddr_in6 ifra_addr;
    struct sockaddr_in6 ifra_dstaddr;
    struct sockaddr_in6 ifra_mask;
    uint32_t ifra_flags;
    struct {
        double ia6t_expire;
        double ia6t_preferred;
        uint32_t ia6t_vltime;
        uint32_t ia6t_pltime;
    } ifra_lifetime;
} ifAliasReq6;

static BOOL ensureTUNMTU(NSString* tunName, uint32_t mtu, NSString** errorMessage);
static BOOL interfaceHasExpectedIPv4(NSString* tunName);
static BOOL ensureTUNIPv4(NSString* tunName, NSString** errorMessage);
static BOOL ensureTUNIPv6(NSString* tunName, NSString** errorMessage);
static int ioctlPtr(int fd, unsigned long req, void* argp);

static int parseUTUNIndex(NSString* preferredName) {
    if (![preferredName isKindOfClass:[NSString class]] || preferredName.length == 0) {
        return -1;
    }

    unsigned int index = 0;
    if (sscanf([preferredName UTF8String], "utun%u", &index) != 1) {
        return -2;
    }
    return (int)index;
}


int createTUN(void) {
    return createTUNWithName(nil, nil);
}

int createTUNWithName(NSString* preferredName, NSString** actualNameOut) {
    int parsedIndex = parseUTUNIndex(preferredName);
    if (parsedIndex == -2) {
        return EINVAL;
    }

    uint32_t ifIndex = (parsedIndex >= 0) ? (uint32_t)parsedIndex : (uint32_t)-1;
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
    memset(ifname, 0, sizeof(ifname));
    socklen_t ifname_len = sizeof(ifname);
    err = getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, ifname, &ifname_len);
    if (err != 0) goto on_error;

    if (actualNameOut != NULL) {
        NSString* actualName = [NSString stringWithUTF8String:ifname] ?: @"";
        if (actualName.length == 0 && parsedIndex >= 0) {
            actualName = [NSString stringWithFormat:@"utun%d", parsedIndex];
        }
        *actualNameOut = actualName;
    }
    
    err = fcntl(fd, F_SETFL, O_NONBLOCK);
    if (err != 0) goto on_error;

on_error:
  if (err != 0) {
    close(fd);
    return -err;
  }

    return fd;
}

BOOL ensureTUNInterfaceReady(NSString* tunName, uint32_t mtu, NSString** errorMessage) {
    if (![tunName isKindOfClass:[NSString class]] || tunName.length == 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"Missing tun interface name for setup.";
        }
        return NO;
    }
    if (!ensureTUNMTU(tunName, mtu, errorMessage)) {
        return NO;
    }
    if (!ensureTUNIPv4(tunName, errorMessage)) {
        return NO;
    }
    (void)ensureTUNIPv6(tunName, nil);
    return YES;
}

BOOL sendFileDescriptor(int socketFD, int fileDescriptor, NSString* payload) {
    if (socketFD < 0 || fileDescriptor < 0) {
        return NO;
    }

    NSData* payloadData = [[payload ?: @"" stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));

    struct iovec io = {
        .iov_base = (void*)payloadData.bytes,
        .iov_len = payloadData.length,
    };

    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &io;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);

    struct cmsghdr* header = CMSG_FIRSTHDR(&message);
    if (header == NULL) {
        return NO;
    }
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    *((int*)CMSG_DATA(header)) = fileDescriptor;
    message.msg_controllen = header->cmsg_len;

    return sendmsg(socketFD, &message, 0) >= 0;
}

static BOOL ensureTUNMTU(NSString* tunName, uint32_t mtu, NSString** errorMessage) {
    if (mtu == 0) {
        return YES;
    }

    int socketFD = socket(AF_INET, SOCK_DGRAM, 0);
    if (socketFD < 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to open socket for tun MTU setup.";
        }
        return NO;
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, [tunName UTF8String], sizeof(ifr.ifr_name));
    if (ioctl(socketFD, SIOCGIFMTU, &ifr) == 0 && ifr.ifr_mtu == (int)mtu) {
        close(socketFD);
        return YES;
    }

    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, [tunName UTF8String], sizeof(ifr.ifr_name));
    ifr.ifr_mtu = (int)mtu;
    BOOL ok = (ioctl(socketFD, SIOCSIFMTU, &ifr) == 0);
    close(socketFD);
    if (!ok && errorMessage != NULL) {
        *errorMessage = @"Failed to configure tun MTU.";
    }
    return ok;
}

static BOOL interfaceHasExpectedIPv4(NSString* tunName) {
    NSTask* task = [[NSTask alloc] init];
    [task setLaunchPath:@"/sbin/ifconfig"];
    [task setArguments:@[tunName]];
    NSPipe* outputPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:[NSPipe pipe]];
    [task launch];
    NSData* outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        return NO;
    }
    NSString* output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    return [output containsString:@"inet 169.254.10.2"] && [output containsString:@"--> 169.254.10.1"];
}

static BOOL ensureTUNIPv4(NSString* tunName, NSString** errorMessage) {
    if (interfaceHasExpectedIPv4(tunName)) {
        return YES;
    }

    int socketFD = socket(AF_INET, SOCK_DGRAM, 0);
    if (socketFD < 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to open socket for tun IPv4 setup.";
        }
        return NO;
    }

    ifAliasReq4 req;
    memset(&req, 0, sizeof(req));
    strlcpy(req.ifra_name, [tunName UTF8String], sizeof(req.ifra_name));

    req.ifra_addr.sin_len = sizeof(struct sockaddr_in);
    req.ifra_addr.sin_family = AF_INET;
    inet_pton(AF_INET, "169.254.10.2", &req.ifra_addr.sin_addr);

    req.ifra_dstaddr.sin_len = sizeof(struct sockaddr_in);
    req.ifra_dstaddr.sin_family = AF_INET;
    inet_pton(AF_INET, TUN_GATEWAY, &req.ifra_dstaddr.sin_addr);

    req.ifra_mask.sin_len = sizeof(struct sockaddr_in);
    req.ifra_mask.sin_family = AF_INET;
    inet_pton(AF_INET, "255.255.255.252", &req.ifra_mask.sin_addr);

    BOOL ok = ioctl(socketFD, SIOCAIFADDR, &req) == 0 || errno == EEXIST;
    close(socketFD);
    if (!ok && errorMessage != NULL) {
        *errorMessage = [NSString stringWithFormat:@"Failed to configure tun IPv4 address (errno=%d).", errno];
    }
    return ok && interfaceHasExpectedIPv4(tunName);
}

static BOOL ensureTUNIPv6(NSString* tunName, NSString** errorMessage) {
    NSString* output = nil;
    NSTask* task = [[NSTask alloc] init];
    [task setLaunchPath:@"/sbin/ifconfig"];
    [task setArguments:@[tunName]];
    NSPipe* outputPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:[NSPipe pipe]];
    [task launch];
    NSData* outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    if ([output containsString:@"inet6 fe80:"]) {
        return YES;
    }

    int socketFD = socket(AF_INET6, SOCK_DGRAM, 0);
    if (socketFD < 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to open socket for tun IPv6 setup.";
        }
        return NO;
    }

    ifAliasReq6 req;
    memset(&req, 0, sizeof(req));
    strlcpy(req.ifra_name, [tunName UTF8String], sizeof(req.ifra_name));

    req.ifra_addr.sin6_len = sizeof(struct sockaddr_in6);
    req.ifra_addr.sin6_family = AF_INET6;
    inet_pton(AF_INET6, "fe80::a9fe:a02", &req.ifra_addr.sin6_addr);

    req.ifra_mask.sin6_len = sizeof(struct sockaddr_in6);
    req.ifra_mask.sin6_family = AF_INET6;
    inet_pton(AF_INET6, "ffff:ffff:ffff:ffff::", &req.ifra_mask.sin6_addr);

    req.ifra_flags = IN6_IFF_NODAD;
    req.ifra_lifetime.ia6t_vltime = ND6_INFINITE_LIFETIME;
    req.ifra_lifetime.ia6t_pltime = ND6_INFINITE_LIFETIME;

    BOOL ok = ioctlPtr(socketFD, SIOCAIFADDR6, &req) == 0 || errno == EEXIST;
    close(socketFD);
    if (!ok && errorMessage != NULL) {
        *errorMessage = [NSString stringWithFormat:@"Failed to configure tun IPv6 address (errno=%d).", errno];
    }
    return ok;
}

static int ioctlPtr(int fd, unsigned long req, void* argp) {
    return ioctl(fd, req, argp);
}
