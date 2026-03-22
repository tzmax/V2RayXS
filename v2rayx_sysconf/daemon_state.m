#import <Foundation/Foundation.h>
#import "daemon_state.h"

NSString* const DAEMON_DATA_PLANE_NONE = @"none";
NSString* const DAEMON_DATA_PLANE_EMBEDDED = @"embedded";
NSString* const DAEMON_DATA_PLANE_FD_HANDOFF = @"fd_handoff";

static NSString* daemonSessionStatus = @"inactive";
static NSString* daemonDataPlaneKind = @"none";
static NSString* daemonTunName = @"";
static NSString* daemonLeaseIdentifier = @"";
static NSString* daemonSocksPort = @"";
static NSString* daemonPendingTunName = @"";
static NSString* daemonPendingLeaseIdentifier = @"";
static int daemonPendingTunFD = -1;
static int daemonActiveTunFD = -1;

void daemonStateReset(void) {
    daemonSessionStatus = @"inactive";
    daemonDataPlaneKind = DAEMON_DATA_PLANE_NONE;
    daemonTunName = @"";
    daemonLeaseIdentifier = @"";
    daemonSocksPort = @"";
    daemonPendingTunName = @"";
    daemonPendingLeaseIdentifier = @"";
    if (daemonPendingTunFD >= 0) {
        close(daemonPendingTunFD);
        daemonPendingTunFD = -1;
    }
    if (daemonActiveTunFD >= 0) {
        close(daemonActiveTunFD);
        daemonActiveTunFD = -1;
    }
}

NSString* daemonStateSessionStatus(void) { return daemonSessionStatus ?: @"inactive"; }
NSString* daemonStateDataPlaneKind(void) { return daemonDataPlaneKind ?: DAEMON_DATA_PLANE_NONE; }
NSString* daemonStateTunName(void) { return daemonTunName ?: @""; }
NSString* daemonStateLeaseIdentifier(void) { return daemonLeaseIdentifier ?: @""; }
NSString* daemonStateSocksPort(void) { return daemonSocksPort ?: @""; }

void daemonStateActivateEmbeddedSession(NSString* tunName, NSInteger socksPort) {
    daemonSessionStatus = @"active";
    daemonDataPlaneKind = DAEMON_DATA_PLANE_EMBEDDED;
    daemonTunName = tunName ?: @"";
    daemonLeaseIdentifier = @"";
    daemonSocksPort = [NSString stringWithFormat:@"%ld", (long)socksPort];
    daemonPendingTunName = @"";
    daemonPendingLeaseIdentifier = @"";
}

BOOL daemonStateStoreFDLease(NSString* leaseId, NSString* tunName, int tunFD, NSString** errorMessage) {
    if (daemonPendingTunFD >= 0 || daemonStateHasPendingLease()) {
        if (errorMessage != NULL) {
            *errorMessage = @"A pending tun lease already exists.";
        }
        return NO;
    }
    daemonPendingLeaseIdentifier = leaseId ?: @"";
    daemonPendingTunName = tunName ?: @"";
    daemonPendingTunFD = tunFD;
    return YES;
}

BOOL daemonStateHasPendingLease(void) {
    return daemonPendingLeaseIdentifier.length > 0 && daemonPendingTunName.length > 0;
}

BOOL daemonStateResolvePendingLease(NSString* requestedLeaseId, NSString** tunNameOut, NSString** leaseIdOut, NSString** errorMessage) {
    if (!daemonStateHasPendingLease()) {
        if (errorMessage != NULL) {
            *errorMessage = @"No pending tun lease is available.";
        }
        return NO;
    }
    if (requestedLeaseId.length > 0 && ![requestedLeaseId isEqualToString:daemonPendingLeaseIdentifier]) {
        if (errorMessage != NULL) {
            *errorMessage = @"Requested lease does not match the pending tun lease.";
        }
        return NO;
    }
    if (tunNameOut != NULL) {
        *tunNameOut = daemonPendingTunName;
    }
    if (leaseIdOut != NULL) {
        *leaseIdOut = daemonPendingLeaseIdentifier;
    }
    return YES;
}

void daemonStateActivatePendingLease(void) {
    daemonSessionStatus = @"active";
    daemonDataPlaneKind = DAEMON_DATA_PLANE_FD_HANDOFF;
    daemonTunName = daemonPendingTunName;
    daemonLeaseIdentifier = daemonPendingLeaseIdentifier;
    daemonSocksPort = @"";
    daemonActiveTunFD = daemonPendingTunFD;
    daemonPendingTunName = @"";
    daemonPendingLeaseIdentifier = @"";
    daemonPendingTunFD = -1;
}

void daemonStateClearLease(void) {
    daemonPendingTunName = @"";
    daemonPendingLeaseIdentifier = @"";
    if (daemonPendingTunFD >= 0) {
        close(daemonPendingTunFD);
        daemonPendingTunFD = -1;
    }
}

BOOL daemonStateIsActive(void) {
    return [daemonSessionStatus isEqualToString:@"active"];
}
