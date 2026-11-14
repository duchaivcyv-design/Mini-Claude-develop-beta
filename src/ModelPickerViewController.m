#import "ModelPickerViewController.h"
#import "Strings.h"
#import "Theme.h"
#import "KeyStore.h"
#import "GeminiClient.h"
#import "ClaudeClient.h"
#import "ModelStore.h"
#import "SystemPromptViewController.h"

@interface ModelPickerViewController ()
@property (copy, nonatomic) NSString *selectedModel;
@property (strong, nonatomic) UITableView *tableView;
@property (strong, nonatomic) UILabel *statusLabel;
@property (assign, nonatomic) NSInteger pendingFetches;
@property (assign, nonatomic) BOOL fetchFailed;
@property (copy, nonatomic) NSArray *groups;   // @[ @{ @"title": ..., @"items": @[model dicts] } ], empty groups omitted
@end

@implementation ModelPickerViewController

- (instancetype)initWithSelectedModel:(NSString *)modelId {
    self = [super init];
    if (self) _selectedModel = [modelId copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"models_title");
    self.view.backgroundColor = [Theme background];
    [self rebuildGroups];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:L(@"refresh") style:UIBarButtonItemStylePlain target:self action:@selector(refresh)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [Theme background];
    self.tableView.separatorColor = [Theme border];
    [self.view addSubview:self.tableView];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:15];
    self.statusLabel.textColor = [Theme secondaryText];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    [self updateStatus];
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.statusLabel.frame = CGRectMake(32, 190, self.view.bounds.size.width - 64, 60);
}

// One group per provider that has a key. Gemini is split into "recommended for free keys" and the rest.
- (void)rebuildGroups {
    NSMutableArray *groups = [NSMutableArray array];
    for (NSNumber *value in [Provider all]) {
        AIProvider provider = (AIProvider)value.integerValue;
        if (![KeyStore hasKeyForProvider:provider]) continue;
        NSArray *models = [ModelStore cachedModelsForProvider:provider];
        if (provider == AIProviderClaude) {
            if (models.count > 0) [groups addObject:@{ @"title": L(@"models_group_claude"), @"items": models }];
            continue;
        }
        NSMutableArray *recommended = [NSMutableArray array], *other = [NSMutableArray array];
        for (NSDictionary *model in models) {
            if ([ModelStore isLikelyFreeModelId:model[@"id"]]) [recommended addObject:model]; else [other addObject:model];
        }
        if (recommended.count > 0) [groups addObject:@{ @"title": L(@"models_group_gemini_free"), @"items": recommended }];
        if (other.count > 0) [groups addObject:@{ @"title": L(@"models_group_gemini_other"), @"items": other }];
    }
    self.groups = groups;
}

// Section 0 is the "instructions for this chat" row; the model groups follow.
- (NSDictionary *)modelAtIndexPath:(NSIndexPath *)indexPath {
    return self.groups[indexPath.section - 1][@"items"][indexPath.row];
}

- (void)updateStatus {
    if (self.groups.count > 0) {
        self.statusLabel.hidden = YES;
    } else {
        self.statusLabel.hidden = NO;
        if (self.pendingFetches > 0) self.statusLabel.text = L(@"loading_models");
        else if (![KeyStore hasAnyKey]) self.statusLabel.text = L(@"models_no_key");
        else self.statusLabel.text = L(@"models_error");
    }
}

- (void)refresh {
    if (self.pendingFetches > 0) return;
    self.fetchFailed = NO;
    for (NSNumber *value in [Provider all]) {
        AIProvider provider = (AIProvider)value.integerValue;
        NSString *key = [KeyStore loadKeyForProvider:provider];
        if (key.length == 0) continue;
        self.pendingFetches++;
        __weak typeof(self) weakSelf = self;
        GeminiModelsCompletion completion = ^(NSArray *models, GeminiCheckResult result) {
            ModelPickerViewController *me = weakSelf;
            if (!me) return;
            me.pendingFetches--;
            if (result == GeminiCheckOK && models.count > 0) {
                [ModelStore saveModels:models forProvider:provider];
            } else {
                me.fetchFailed = YES;
            }
            if (me.pendingFetches == 0) {
                [me rebuildGroups];
                [me.tableView reloadData];
                [me updateStatus];
            }
        };
        if (provider == AIProviderClaude) [ClaudeClient fetchModelsWithKey:key completion:completion];
        else [GeminiClient fetchModelsWithKey:key completion:completion];
    }
    [self updateStatus];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.groups.count + 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : (NSInteger)[self.groups[section - 1][@"items"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? nil : self.groups[section - 1][@"title"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.backgroundColor = [Theme surface];
        cell.textLabel.font = [UIFont systemFontOfSize:17];
        cell.textLabel.textColor = [Theme text];
        cell.textLabel.text = L(@"chat_prompt_title");
        cell.detailTextLabel.font = [UIFont systemFontOfSize:15];
        cell.detailTextLabel.textColor = [Theme secondaryText];
        cell.detailTextLabel.text = self.chatPrompt.length > 0 ? L(@"system_prompt_set") : L(@"chat_prompt_default");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [Theme surface];
    cell.textLabel.font = [UIFont systemFontOfSize:17];
    cell.textLabel.textColor = [Theme text];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.textColor = [Theme secondaryText];

    NSDictionary *model = [self modelAtIndexPath:indexPath];
    NSString *modelId = model[@"id"];
    cell.textLabel.text = [model[@"name"] isKindOfClass:[NSString class]] ? model[@"name"] : modelId;
    cell.detailTextLabel.text = modelId;
    BOOL selected = [modelId isEqualToString:self.selectedModel];
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [Theme accent];
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return (self.groups.count > 0 && section == (NSInteger)self.groups.count) ? L(@"models_footer") : nil;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        SystemPromptViewController *editor = [[SystemPromptViewController alloc] init];
        editor.perConversation = YES;
        editor.initialText = self.chatPrompt;
        __weak typeof(self) weakSelf = self;
        editor.onSave = ^(NSString *text) {
            ModelPickerViewController *me = weakSelf;
            if (!me) return;
            me.chatPrompt = text;
            if (me.onChatPromptChange) me.onChatPromptChange(text);
            [me.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
        };
        [self.navigationController pushViewController:editor animated:YES];
        return;
    }
    NSString *modelId = [self modelAtIndexPath:indexPath][@"id"];
    if (self.onSelect) self.onSelect(modelId);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
