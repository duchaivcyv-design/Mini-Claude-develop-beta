#import "SettingsViewController.h"
#import "Strings.h"
#import "Theme.h"
#import "KeyStore.h"
#import "AppSettings.h"
#import "ConversationStore.h"
#import "RootViewController.h"
#import "SystemPromptViewController.h"
#import "DiagnosticsViewController.h"

typedef NS_ENUM(NSInteger, SettingsSection) {
    SettingsSectionKeys = 0,
    SettingsSectionAssistant,
    SettingsSectionGeneral,
    SettingsSectionHistory,
    SettingsSectionAbout,
    SettingsSectionCount
};

@interface SettingsViewController ()
@property (strong, nonatomic) UITableView *tableView;
@end

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"settings_title");
    self.view.backgroundColor = [Theme background];
    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [Theme background];
    self.tableView.separatorColor = [Theme border];
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];   // keys / system prompt may have changed on the next screen
}

#pragma mark - Helpers

- (NSString *)maskedKeyFor:(AIProvider)provider {
    NSString *key = [KeyStore loadKeyForProvider:provider];
    if (key.length == 0) return L(@"api_key_none");
    NSString *tail = key.length > 4 ? [key substringFromIndex:key.length - 4] : key;
    return [@"\u2022\u2022\u2022\u2022" stringByAppendingString:tail];
}

- (NSString *)languageName {
    NSString *preference = [Loc preference];
    if ([preference isEqualToString:@"vi"]) return @"Ti\u1EBFng Vi\u1EC7t";
    if ([preference isEqualToString:@"en"]) return @"English";
    return L(@"language_auto");
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return SettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == SettingsSectionKeys || section == SettingsSectionAbout) return 2;
    if (section == SettingsSectionAssistant) return 4;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == SettingsSectionKeys ? L(@"keys_header") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == SettingsSectionKeys) return L(@"keys_footer");
    if (section == SettingsSectionAssistant) return L(@"attach_memory_footer");
    if (section == SettingsSectionAbout) return L(@"privacy_footer");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.backgroundColor = [Theme surface];
    cell.textLabel.font = [UIFont systemFontOfSize:17];
    cell.textLabel.textColor = [Theme text];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:16];
    cell.detailTextLabel.textColor = [Theme secondaryText];

    switch (indexPath.section) {
        case SettingsSectionKeys: {
            AIProvider provider = indexPath.row == 0 ? AIProviderGemini : AIProviderClaude;
            cell.textLabel.text = provider == AIProviderClaude ? L(@"api_key_claude") : L(@"api_key_gemini");
            cell.detailTextLabel.text = [self maskedKeyFor:provider];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case SettingsSectionAssistant:
            if (indexPath.row == 0) {
                cell.textLabel.text = L(@"system_prompt_title");
                cell.detailTextLabel.text = [AppSettings systemPrompt].length > 0 ? L(@"system_prompt_set") : L(@"system_prompt_unset");
            } else if (indexPath.row == 1) {
                cell.textLabel.text = L(@"attach_memory_title");
                cell.detailTextLabel.text = [self attachmentMemoryName];
            } else if (indexPath.row == 2) {
                cell.textLabel.text = L(@"output_tokens_title");
                cell.detailTextLabel.text = [self outputTokensName];
            } else {
                cell.textLabel.text = L(@"context_memory_title");
                cell.detailTextLabel.text = [self contextMemoryName];
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case SettingsSectionGeneral:
            cell.textLabel.text = L(@"language");
            cell.detailTextLabel.text = [self languageName];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case SettingsSectionHistory:
            cell.textLabel.text = L(@"clear_history");
            cell.textLabel.textColor = [Theme error];
            break;
        default:
            if (indexPath.row == 0) {
                cell.textLabel.text = L(@"version");
                cell.detailTextLabel.text = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                cell.textLabel.text = L(@"diagnostics_title");
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            break;
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case SettingsSectionKeys: {
            RootViewController *keyScreen = [[RootViewController alloc] init];
            keyScreen.embedded = YES;
            keyScreen.provider = indexPath.row == 0 ? AIProviderGemini : AIProviderClaude;
            [self.navigationController pushViewController:keyScreen animated:YES];
            break;
        }
        case SettingsSectionAssistant:
            if (indexPath.row == 0) {
                [self.navigationController pushViewController:[[SystemPromptViewController alloc] init] animated:YES];
            } else if (indexPath.row == 1) {
                [self chooseAttachmentMemory];
            } else if (indexPath.row == 2) {
                [self chooseOutputTokens];
            } else {
                [self chooseContextMemory];
            }
            break;
        case SettingsSectionGeneral:
            [self chooseLanguage];
            break;
        case SettingsSectionHistory:
            [self confirmClearHistory];
            break;
        default:
            if (indexPath.row == 1) [self.navigationController pushViewController:[[DiagnosticsViewController alloc] init] animated:YES];
            break;
    }
}

#pragma mark - Attachment memory and request limits

- (NSString *)attachmentMemoryName {
    NSInteger count = [AppSettings attachmentMemory];
    if (count == 1) return L(@"attach_memory_1");
    if (count == 0) return L(@"attach_memory_all");
    return L(@"attach_memory_3");
}

- (NSString *)outputTokensName {
    return [NSString stringWithFormat:@"%ld tokens", (long)[AppSettings maxOutputTokens]];
}

- (NSString *)contextMemoryName {
    // Hiển thị trạng thái Vô thời hạn cho lịch sử AI theo yêu cầu mới
    return @"Vô thời hạn (Tùy server API)";
}

- (void)chooseOutputTokens {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"output_tokens_title")
                                                                   message:L(@"output_tokens_note")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *options = @[ @[@2048, @"2,048 tokens"], @[@4096, @"4,096 tokens"], @[@8192, @"8,192 tokens"], @[@16384, @"16,384 tokens"], @[@32768, @"32,768 tokens"], @[@65536, @"65,536 tokens"], @[@128000, @"128,000 tokens"] ];
    __weak typeof(self) weakSelf = self;
    for (NSArray *option in options) {
        NSInteger value = [option[0] integerValue];
        [sheet addAction:[UIAlertAction actionWithTitle:option[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [AppSettings setMaxOutputTokens:value];
            [weakSelf.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    NSIndexPath *path = [NSIndexPath indexPathForRow:2 inSection:SettingsSectionAssistant];
    sheet.popoverPresentationController.sourceView = [self.tableView cellForRowAtIndexPath:path] ?: self.view;
    sheet.popoverPresentationController.sourceRect = sheet.popoverPresentationController.sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)chooseContextMemory {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"context_memory_title")
                                                                   message:@"Lịch sử trò chuyện gửi cho AI đã được thiết lập vô thời hạn, tự động mở rộng theo khả năng đáp ứng của server API."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đã hiểu (Vô thời hạn)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [AppSettings setContextLimitChars:200000000];
        [weakSelf.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    NSIndexPath *path = [NSIndexPath indexPathForRow:3 inSection:SettingsSectionAssistant];
    sheet.popoverPresentationController.sourceView = [self.tableView cellForRowAtIndexPath:path] ?: self.view;
    sheet.popoverPresentationController.sourceRect = sheet.popoverPresentationController.sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)chooseAttachmentMemory {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"attach_memory_title")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *options = @[ @[@1, L(@"attach_memory_1")], @[@3, L(@"attach_memory_3")], @[@0, L(@"attach_memory_all")] ];
    __weak typeof(self) weakSelf = self;
    for (NSArray *option in options) {
        NSInteger value = [option[0] integerValue];
        [sheet addAction:[UIAlertAction actionWithTitle:option[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [AppSettings setAttachmentMemory:value];
            [weakSelf.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    NSIndexPath *path = [NSIndexPath indexPathForRow:1 inSection:SettingsSectionAssistant];
    sheet.popoverPresentationController.sourceView = [self.tableView cellForRowAtIndexPath:path] ?: self.view;
    sheet.popoverPresentationController.sourceRect = sheet.popoverPresentationController.sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Language

- (void)chooseLanguage {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"language")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *options = @[ @[@"auto", L(@"language_auto")], @[@"vi", @"Ti\u1EBFng Vi\u1EC7t"], @[@"en", @"English"] ];
    for (NSArray *option in options) {
        NSString *value = option[0];
        UIAlertAction *action = [UIAlertAction actionWithTitle:option[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if ([[Loc preference] isEqualToString:value]) return;
            [Loc setPreference:value];
            [[NSNotificationCenter defaultCenter] postNotificationName:kNotifLanguageChanged object:nil];
        }];
        [sheet addAction:action];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    NSIndexPath *path = [NSIndexPath indexPathForRow:0 inSection:SettingsSectionGeneral];
    sheet.popoverPresentationController.sourceView = [self.tableView cellForRowAtIndexPath:path] ?: self.view;
    sheet.popoverPresentationController.sourceRect = sheet.popoverPresentationController.sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - History

- (void)confirmClearHistory {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"clear_history_confirm_title")
                                                                   message:L(@"clear_history_confirm_msg")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:L(@"delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [ConversationStore deleteAll];
        [[NSNotificationCenter defaultCenter] postNotificationName:kNotifHistoryCleared object:nil];
        SettingsViewController *me = weakSelf;
        if (!me) return;
        UIAlertController *done = [UIAlertController alertControllerWithTitle:nil
                                                                      message:L(@"history_cleared")
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [me presentViewController:done animated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
