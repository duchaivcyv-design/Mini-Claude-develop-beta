#import <Foundation/Foundation.h>
#import "Provider.h"

// Remembers each provider's model list (fetched live with the user's key) and the chosen model.
// Model names are never hard-coded: they change over time and differ per account.
@interface ModelStore : NSObject

+ (NSArray *)cachedModelsForProvider:(AIProvider)provider;          // @[ @{ @"id":..., @"name":... } ]
+ (void)saveModels:(NSArray *)models forProvider:(AIProvider)provider;

+ (NSString *)selectedModelId;                                      // nil if the user never chose one
+ (void)setSelectedModelId:(NSString *)modelId;

// Hint by model family, not by version: Gemini's Flash / Flash-Lite families are the ones on Google's free tier;
// Pro, Argon and similar usually need billing. The API does not report this, so it is a hint, not a guarantee.
+ (BOOL)isLikelyFreeModelId:(NSString *)modelId;

// A sensible default for one provider. Gemini: the newest stable "gemini-X.Y-flash", else a non-preview Flash,
// else any Flash, else the first. Claude: the newest Sonnet, else the first.
+ (NSString *)defaultModelIdForProvider:(AIProvider)provider models:(NSArray *)models;

// A default across providers: Gemini first (it has a free tier), then Claude; only providers that have a key and a cached list.
+ (NSString *)defaultModelIdAcrossProviders;

@end
