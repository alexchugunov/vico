#import "ViRegisterManager.h"
#import "ViWindowController.h"
#include "logging.h"

@implementation ViRegisterManager

@synthesize lastExecutedRegister = _lastExecutedRegister;

+ (id)sharedManager
{
	static ViRegisterManager *__sharedManager = nil;
	if (__sharedManager == nil)
		__sharedManager = [[ViRegisterManager alloc] init];
	return __sharedManager;
}

- (id)init
{
	if ((self = [super init]) != nil) {
		_registers = [[NSMutableDictionary alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[_registers release];
	[super dealloc];
}

- (NSString *)contentOfRegister:(unichar)regName
{
	if (regName == '*' || regName == '+') {
		NSPasteboard *pasteBoard = [NSPasteboard generalPasteboard];
		[pasteBoard types];
		return [pasteBoard stringForType:NSStringPboardType];	
	} else if (regName == '%') {
		return [[[[ViWindowController currentWindowController] currentDocument] fileURL] absoluteString];
	} else if (regName == '#') {
		return [[[[ViWindowController currentWindowController] previousDocument] fileURL] absoluteString];
	} else if (regName == '_')
		return @"";

	if (regName >= 'A' && regName <= 'Z')
		regName = tolower(regName);
	return [_registers objectForKey:[self nameOfRegister:regName]];
}

- (void)setContent:(NSString *)content ofRegister:(unichar)regName
{
	if (regName == '_')
		return;

	if (content == nil)
		content = @"";

	if (regName == '*' || regName == '+' || (regName == 0 && [[NSUserDefaults standardUserDefaults] boolForKey:@"clipboard"])) {
		NSPasteboard *pasteBoard = [NSPasteboard generalPasteboard];
		[pasteBoard declareTypes:[NSArray arrayWithObjects:NSStringPboardType, nil]
				   owner:nil];
		[pasteBoard setString:content forType:NSStringPboardType];
	}

	/* Uppercase registers append. */
	if (regName >= 'A' && regName <= 'Z') {
		regName = tolower(regName);
		NSString *currentContent = [self contentOfRegister:regName];
		if (currentContent)
			content = [currentContent stringByAppendingString:content];
	}

	[_registers setObject:content forKey:[self nameOfRegister:regName]];
	if (regName != 0 && regName != '"' && regName != '/' && regName != ':')
		[_registers setObject:content forKey:[self nameOfRegister:0]];
}

- (NSString *)nameOfRegister:(unichar)regName
{
	if (regName == 0 || regName == '"')
		return @"unnamed";
	else if (regName == '*' || regName == '+')
		return @"pasteboard";
	else if (regName == '%')
		return @"current file";
	else if (regName == '#')
		return @"alternate file";
	else if (regName == ':')
		return @"last ex command";
	else
		return [NSString stringWithFormat:@"%C", regName];
}

@end
