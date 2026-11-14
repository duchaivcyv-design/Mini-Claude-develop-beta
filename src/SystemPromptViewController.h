#import <UIKit/UIKit.h>

// Edits the instructions sent to the model with every message (the "system prompt"). Saved automatically.
@interface SystemPromptViewController : UIViewController <UITextViewDelegate>

// Per-conversation mode: edits `initialText` and reports the result through onSave (an empty string means
// "use the general instructions"). When perConversation is NO (the default) it edits the general instructions.
@property (assign, nonatomic) BOOL perConversation;
@property (copy, nonatomic) NSString *initialText;
@property (copy, nonatomic) void (^onSave)(NSString *text);

@end
