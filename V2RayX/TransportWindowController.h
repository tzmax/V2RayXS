//
//  TransportWindowController.h
//  V2RayX
//
//

#import <Cocoa/Cocoa.h>
#import "ConfigWindowController.h"
#import "utilities.h"
#import "TLSCertSha256.h"

NS_ASSUME_NONNULL_BEGIN

@interface TransportWindowController : NSWindowController

- (instancetype)initWithWindowNibName:(NSNibName)windowNibName parentController:(ConfigWindowController*)parent;

- (BOOL)checkInputs;
- (NSArray*)generateSettings;
- (CGFloat)tlsPanelHeight;

@property (nonatomic, getter=tlsPanelHeight) CGFloat tlsPanelHeight;

//kcp fields
@property (weak) IBOutlet NSTextField *kcpMtuField;
@property (weak) IBOutlet NSTextField *kcpTtiField;
@property (weak) IBOutlet NSTextField *kcpUcField;
@property (weak) IBOutlet NSTextField *kcpDcField;
@property (weak) IBOutlet NSTextField *kcpRbField;
@property (weak) IBOutlet NSTextField *kcpWbField;
@property (weak) IBOutlet NSTextField *kcpSeedField;
@property (weak) IBOutlet NSPopUpButton *kcpCongestionButton;
@property (weak) IBOutlet NSPopUpButton *kcpHeaderTypeButton;
//tcp fields
@property (weak) IBOutlet NSButton *tcpHeaderCusButton;
@property (unsafe_unretained) IBOutlet NSTextView *tcpHeaderField;


//ws fields
@property (weak) IBOutlet NSTextField *wsPathField;
@property (unsafe_unretained) IBOutlet NSTextView *wsHeaderField;
//https fields
@property (weak) IBOutlet NSTextField *httpHostsField;
@property (weak) IBOutlet NSTextField *httpPathField;

// quic fields
@property (weak) IBOutlet NSPopUpButton *quicSecurityButton;
@property (weak) IBOutlet NSTextField *quicKeyField;
@property (weak) IBOutlet NSPopUpButton *quicHeaderButton;


//tls fields
@property (weak) IBOutlet NSPopUpButton *tlsSecurityButton;
@property (weak) IBOutlet NSButton *tlsAiButton;
@property (weak) IBOutlet NSButton *tlsAllowInsecureCiphersButton;
@property (weak) IBOutlet NSTextField *tlsAlpnField;
@property (weak) IBOutlet NSTextField *tlsServerNameField;
@property (weak) IBOutlet NSTextField *tlsPinnedPeerCertSha256Field;
@property (weak) IBOutlet NSTextField *tlsVerifyPeerCertByNameField;
@property (weak) IBOutlet NSTextField *tlsAutoPinStatusField;
@property (weak) IBOutlet NSButton *tlsRefreshAutoPinButton;
@property (weak) IBOutlet NSView *tlsConfigurationPanel;

- (IBAction)tlsSecurityChange:(NSPopUpButton *)sender;
- (IBAction)refreshAutoPinnedPeerCertSha256:(id)sender;


//reality fields
@property (weak) IBOutlet NSView *realityControlPanel;
@property (weak) IBOutlet NSTextField *realityFingerprint;
@property (weak) IBOutlet NSTextField *realityShortID;
@property (weak) IBOutlet NSTextField *realitySpiderX;
@property (weak) IBOutlet NSTextField *realityPubilcKey;

//mux fields
@property (weak) IBOutlet NSButton *muxEnableButton;
@property (weak) IBOutlet NSTextField *muxConcurrencyField;

//tcp fast open
@property (weak) IBOutlet NSButton *tfoEnableButton;

// grpc fields
@property (weak) IBOutlet NSTextField *grpcServiceNameField;
@property (weak) IBOutlet NSPopUpButton *grpcMultiMode;


@end

NS_ASSUME_NONNULL_END
