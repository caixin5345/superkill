//
//  SKMainViewController.m
//  SuperKill
//
//  极简操作台：App Group → 自检 → 彻底清除。
//

#import "SKMainViewController.h"
#import "SKEngine.h"

@interface SKMainViewController () <UITextFieldDelegate>

@property (nonatomic, strong) SKEngine *engine;
@property (nonatomic, strong) UITextField *groupField;
@property (nonatomic, strong) UITextView *console;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic, strong) dispatch_queue_t workQueue;

@end

@implementation SKMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    NSString *displayName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    self.title = displayName.length ? displayName : @"琼崖海南麻将";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.engine = [[SKEngine alloc] init];
    self.workQueue = dispatch_queue_create("cc.superkill.work", DISPATCH_QUEUE_SERIAL);
    self.logBuffer = [NSMutableString string];

    __weak typeof(self) weakSelf = self;
    self.engine.logger = ^(NSString *line) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf appendLog:line];
        });
    };

    [self buildUI];
    self.groupField.text = [SKEngine configuredAppGroup];
    [self appendLog:@"就绪：① 自检看状态，② 彻底清除监管。"];
}

#pragma mark - UI

- (UIButton *)makeButton:(NSString *)title action:(SEL)action destructive:(BOOL)destructive {
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = title;
    config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    if (destructive) {
        config.baseBackgroundColor = [UIColor systemRedColor];
    }
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    return button;
}

- (UILabel *)makeSectionLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = [UIColor secondaryLabelColor];
    return label;
}

- (void)buildUI {
    UIStackView *root = [[UIStackView alloc] init];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 10;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:root];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:guide.topAnchor constant:16],
        [root.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [root.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
        [root.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12],
    ]];

    UIStackView *groupRow = [[UIStackView alloc] init];
    groupRow.axis = UILayoutConstraintAxisHorizontal;
    groupRow.spacing = 8;

    self.groupField = [[UITextField alloc] init];
    self.groupField.borderStyle = UITextBorderStyleRoundedRect;
    self.groupField.placeholder = @"group.yourteam.superkill";
    self.groupField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.groupField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.groupField.delegate = self;
    self.groupField.returnKeyType = UIReturnKeyDone;
    self.groupField.font = [UIFont systemFontOfSize:14];
    [self.groupField.heightAnchor constraintEqualToConstant:40].active = YES;

    UIButton *save = [self makeButton:@"保存" action:@selector(saveGroup) destructive:NO];
    [save.widthAnchor constraintEqualToConstant:72].active = YES;

    [groupRow addArrangedSubview:self.groupField];
    [groupRow addArrangedSubview:save];

    [root addArrangedSubview:[self makeSectionLabel:@"App Group（App 会自动读签名里的，一般不用改）"]];
    [root addArrangedSubview:groupRow];
    [root addArrangedSubview:[self makeButton:@"① 自检（系统 / Group / 监管状态）" action:@selector(runEnvironment) destructive:NO]];
    [root addArrangedSubview:[self makeButton:@"② 彻底清除监管" action:@selector(confirmWipe) destructive:YES]];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [root addArrangedSubview:self.spinner];

    self.console = [[UITextView alloc] init];
    self.console.editable = NO;
    self.console.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.console.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.console.layer.cornerRadius = 8;
    self.console.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.console.heightAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;
    [root addArrangedSubview:self.console];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)saveGroup {
    [self.groupField resignFirstResponder];
    NSString *group = [self.groupField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [SKEngine setConfiguredAppGroup:group];
    self.engine.appGroup = group;
    [self appendLog:[NSString stringWithFormat:@"App Group 已保存: %@", group.length ? group : @"(空)"]];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self saveGroup];
    return YES;
}

#pragma mark - 日志 / 忙碌状态

- (void)appendLog:(NSString *)line {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss";
    NSString *stamp = [formatter stringFromDate:[NSDate date]];
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", stamp, line];
    [self.logBuffer appendString:entry];
    self.console.text = self.logBuffer;
    if (self.console.text.length > 0) {
        NSRange end = NSMakeRange(self.console.text.length - 1, 1);
        [self.console scrollRangeToVisible:end];
    }
}

- (void)setBusy:(BOOL)busy {
    self.view.userInteractionEnabled = !busy;
    if (busy) [self.spinner startAnimating];
    else [self.spinner stopAnimating];
}

- (void)runInBackground:(void (^)(void))block {
    [self setBusy:YES];
    dispatch_async(self.workQueue, ^{
        @autoreleasepool {
            block();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBusy:NO];
        });
    });
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Actions

- (void)runEnvironment {
    [self saveGroup];
    [self runInBackground:^{
        SKEngine *engine = self.engine;
        SKLogBlock logger = engine.logger;
        if (logger) logger([engine environmentReport]);
    }];
}

- (void)confirmWipe {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"彻底清除监管"
                                                                  message:@"将删除 CloudConfigurationDetails.plist、MDM.plist、MDMEvents.plist、MDMAppManagement.plist、PayloadManifest 条目与全部 GUID.stub，并清空 DeviceManagement 下的状态。"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"继续（彻底）"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [self performWipe];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)performWipe {
    [self runInBackground:^{
        NSError *error = nil;
        BOOL ok = [self.engine wipeSupervision:YES error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self alert:ok ? @"已清除" : @"清除失败"
                        message:ok ? @"保持飞行模式，重启设备后再联网验证：设置 → 通用 → VPN 与设备管理 中不应再有 MDM 描述文件，设置首页不应再显示“此 iPhone 受监管”。"
                                   : (error.localizedDescription ?: @"未知错误")];
        });
    }];
}

@end
