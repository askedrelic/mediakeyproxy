// Copyright (c) 2010 Spotify AB
#import "SPMediaKeyTap.h"

@interface SPMediaKeyTap ()
-(BOOL)shouldInterceptMediaKeyEvents;
-(void)setShouldInterceptMediaKeyEvents:(BOOL)newSetting;
-(void)startWatchingAppSwitching;
-(void)stopWatchingAppSwitching;
-(void)eventTapThread;
@end
static SPMediaKeyTap *singleton = nil;

static pascal OSStatus appSwitched (EventHandlerCallRef nextHandler, EventRef evt, void* userData);
static pascal OSStatus appTerminated (EventHandlerCallRef nextHandler, EventRef evt, void* userData);
static CGEventRef tapEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon);


// Inspired by http://gist.github.com/546311

@implementation SPMediaKeyTap

#pragma mark -
#pragma mark Setup and teardown
-(id)initWithDelegate:(id)delegate;
{
	_delegate = delegate;
	[self startWatchingAppSwitching];
	singleton = self;
	_mediaKeyAppList = [NSMutableArray new];
    _tapThreadRL=nil;
    _eventPort=nil;
    _eventPortSource=nil;
	return self;
}
-(void)dealloc;
{
	[self stopWatchingMediaKeys];
	[self stopWatchingAppSwitching];
	[_mediaKeyAppList release];
	[super dealloc];
}

-(void)startWatchingAppSwitching;
{
	// Listen to "app switched" event, so that we don't intercept media keys if we
	// weren't the last "media key listening" app to be active
	EventTypeSpec eventType = { kEventClassApplication, kEventAppFrontSwitched };
    OSStatus err = InstallApplicationEventHandler(NewEventHandlerUPP(appSwitched), 1, &eventType, self, &_app_switching_ref);
	assert(err == noErr);
	
	eventType.eventKind = kEventAppTerminated;
    err = InstallApplicationEventHandler(NewEventHandlerUPP(appTerminated), 1, &eventType, self, &_app_terminating_ref);
	assert(err == noErr);
}
-(void)stopWatchingAppSwitching;
{
	if(!_app_switching_ref) return;
	RemoveEventHandler(_app_switching_ref);
	_app_switching_ref = NULL;
}

-(void)startWatchingMediaKeys;{
    // Prevent having multiple mediaKeys threads
    [self stopWatchingMediaKeys];
    
	[self setShouldInterceptMediaKeyEvents:YES];
	
	// Add an event tap to intercept the system defined media key events
	_eventPort = CGEventTapCreate(kCGSessionEventTap,
								  kCGHeadInsertEventTap,
								  kCGEventTapOptionDefault,
								  CGEventMaskBit(NX_SYSDEFINED),
								  tapEventCallback,
								  self);
	assert(_eventPort != NULL);
	
    _eventPortSource = CFMachPortCreateRunLoopSource(kCFAllocatorSystemDefault, _eventPort, 0);
	assert(_eventPortSource != NULL);
	
	// Let's do this in a separate thread so that a slow app doesn't lag the event tap
	[NSThread detachNewThreadSelector:@selector(eventTapThread) toTarget:self withObject:nil];
}
-(void)stopWatchingMediaKeys;
{
	// TODO<nevyn>: Shut down thread, remove event tap port and source
    
    if(_tapThreadRL){
        CFRunLoopStop(_tapThreadRL);
        _tapThreadRL=nil;
    }
    
    if(_eventPort){
        CFMachPortInvalidate(_eventPort);
        CFRelease(_eventPort);
        _eventPort=nil;
    }
    
    if(_eventPortSource){
        CFRelease(_eventPortSource);
        _eventPortSource=nil;
    }
}

#pragma mark -
#pragma mark Accessors

+(BOOL)usesGlobalMediaKeyTap
{
    return YES;
//#ifdef _DEBUG
//	// breaking in gdb with a key tap inserted sometimes locks up all mouse and keyboard input forever, forcing reboot
//	return NO;
//#else
//	// XXX(nevyn): MediaKey event tap doesn't work on 10.4, feel free to figure out why if you have the energy.
//	return 
//		![[NSUserDefaults standardUserDefaults] boolForKey:kIgnoreMediaKeysDefaultsKey]
//		&& floor(NSAppKitVersionNumber) >= 949/*NSAppKitVersionNumber10_5*/;
//#endif
}

+ (NSArray*)defaultMediaKeyUserBundleIdentifiers;
{
	return [NSArray arrayWithObjects:
		[[NSBundle mainBundle] bundleIdentifier], // your app
		@"com.spotify.client",
		@"com.apple.iTunes",
		@"com.apple.QuickTimePlayerX",
		@"com.apple.quicktimeplayer",
		@"com.apple.iWork.Keynote",
		@"com.apple.iPhoto",
		@"org.videolan.vlc",
		@"com.apple.Aperture",
		@"com.plexsquared.Plex",
		@"com.soundcloud.desktop",
		@"org.niltsh.MPlayerX",
		@"com.ilabs.PandorasHelper",
		@"com.mahasoftware.pandabar",
		@"com.bitcartel.pandorajam",
		@"org.clementine-player.clementine",
		@"fm.last.Last.fm",
		@"fm.last.Scrobbler",
		@"com.beatport.BeatportPro",
		@"com.Timenut.SongKey",
        @"net.sai9.MediaKeys",
		@"com.macromedia.fireworks", // the tap messes up their mouse input
		nil
	];
}


-(BOOL)shouldInterceptMediaKeyEvents;
{
	BOOL shouldIntercept = NO;
	@synchronized(self) {
		shouldIntercept = _shouldInterceptMediaKeyEvents;
	}
	return shouldIntercept;
}

-(void)pauseTapOnTapThread:(BOOL)yeahno;
{
	CGEventTapEnable(self->_eventPort, yeahno);
}
-(void)setShouldInterceptMediaKeyEvents:(BOOL)newSetting;
{
	BOOL oldSetting;
	@synchronized(self) {
		oldSetting = _shouldInterceptMediaKeyEvents;
		_shouldInterceptMediaKeyEvents = newSetting;
	}
	if(_tapThreadRL && oldSetting != newSetting) {
        NSMethodSignature* sig = [[self class] instanceMethodSignatureForSelector:@selector(pauseTapOnTapThread:)];
        NSInvocation* invoc = [NSInvocation invocationWithMethodSignature:sig];
        [invoc setTarget:self];
        [invoc setSelector:@selector(pauseTapOnTapThread:)];
        [invoc setArgument:&newSetting atIndex:2]; // 0 and 1 are target and selector
        NSTimer* timer = [NSTimer timerWithTimeInterval:0 invocation:invoc repeats:NO];
		CFRunLoopAddTimer(_tapThreadRL, (CFRunLoopTimerRef)timer, kCFRunLoopCommonModes);
	}
}

#pragma mark 
#pragma mark -
#pragma mark Event tap callbacks

// Note: method called on background thread

static CGEventRef tapEventCallback2(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
	SPMediaKeyTap *self = refcon;

    if(type == kCGEventTapDisabledByTimeout) {
		NSLog(@"Media key event tap was disabled by timeout");
		CGEventTapEnable(self->_eventPort, TRUE);
		return event;
	} else if(type == kCGEventTapDisabledByUserInput) {
		// Was disabled manually by -[pauseTapOnTapThread]
		return event;
	}
	NSEvent *nsEvent = nil;
	@try {
		nsEvent = [NSEvent eventWithCGEvent:event];
	}
	@catch (NSException * e) {
		NSLog(@"Strange CGEventType: %d: %@", type, e);
		assert(0);
		return event;
	}


    if (type != NX_SYSDEFINED || [nsEvent subtype] != SPSystemDefinedEventMediaKeys)
		return event;

    NSLog(@"type %d", type == NX_KEYUP);
	int keyCode = (([nsEvent data1] & 0xFFFF0000) >> 16);
    if (keyCode != NX_KEYTYPE_PLAY && keyCode != NX_KEYTYPE_FAST && keyCode != NX_KEYTYPE_REWIND && keyCode != NX_KEYTYPE_PREVIOUS && keyCode != NX_KEYTYPE_NEXT)
		return event;
    
    
    //figure out list of support program, run command to figure out if any are running
    NSString *outputPianobar = runCommand(@"/bin/ps -A -o pid,command | grep p[i]anobar");
    NSString *outputCmus = runCommand(@"/bin/ps -A -o pid,command | grep c[m]us");
    
	int keyFlags = ([nsEvent data1] & 0x0000FFFF);
	BOOL keyIsPressed = (((keyFlags & 0xFF00) >> 8)) == 0xA;
	//int keyRepeat = (keyFlags & 0x1);
    
    //put this into list of with priority?
    if ([outputPianobar length] > 0) {
        
        if (keyIsPressed && keyCode == NX_KEYTYPE_PLAY) {
            NSLog(@"playing");
            runCommand(@"echo -n 'p' > ~/.config/pianobar/ctl");
        }
        
        return NULL;
    } else if ([outputCmus length] > 0) {
        if (keyIsPressed && keyCode == NX_KEYTYPE_PLAY) {
            // figure out if cmus is running
            NSString *outputCmusPlaying = runCommand(@"cmus-remote -Q | grep playing");
            if ([outputCmusPlaying length] > 0) {
                NSLog(@"cmus playing");
                runCommand(@"cmus-remote -u");
            } else {
                NSLog(@"cmus paused");
                runCommand(@"cmus-remote -p");
            }
        }
        
    } else {
        NSLog(@"regular event");
        return event;
    }
    

//	if (![self shouldInterceptMediaKeyEvents])
//		return event;

//	[nsEvent retain]; // matched in handleAndReleaseMediaKeyEvent:
//	[self performSelectorOnMainThread:@selector(handleAndReleaseMediaKeyEvent:) withObject:nsEvent waitUntilDone:NO];
	
	return NULL;
}

static CGEventRef tapEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
    @autoreleasepool {
        CGEventRef ret = tapEventCallback2(proxy, type, event, refcon);
        return ret;
    }
}


// event will have been retained in the other thread
-(void)handleAndReleaseMediaKeyEvent:(NSEvent *)event {
	[event autorelease];
	
//	[_delegate mediaKeyTap:self receivedMediaKeyEvent:event];
}


-(void)eventTapThread;
{
	_tapThreadRL = CFRunLoopGetCurrent();
	CFRunLoopAddSource(_tapThreadRL, _eventPortSource, kCFRunLoopCommonModes);
	CFRunLoopRun();
}

#pragma mark Task switching callbacks

NSString *kMediaKeyUsingBundleIdentifiersDefaultsKey = @"SPApplicationsNeedingMediaKeys";
NSString *kIgnoreMediaKeysDefaultsKey = @"SPIgnoreMediaKeys";

NSString *runCommand(NSString *commandToRun)
{
    NSTask *task;
    task = [[NSTask alloc] init];
    [task setLaunchPath: @"/bin/bash"];
    
    // get current env dictionary
    NSDictionary *environmentDictStatic = [[NSProcessInfo processInfo] environment];
    NSMutableDictionary *environmentDict = [environmentDictStatic mutableCopy];
    
    //NSLog(@"%@", environmentDict);
    
    // update PATH to include usr/local paths
    // TODO: should probably extend PATH, not overwrite PATH
    [environmentDict setObject:@"/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin" forKey:@"PATH"];
    
    // unset these env vars to hide some 10.8 bug
    // http://stackoverflow.com/questions/12064725/dyld-dyld-environment-variables-being-ignored-because-main-executable-usr-bi
    [environmentDict removeObjectForKey:@"DYLD_LIBRARY_PATH"];
    [environmentDict removeObjectForKey:@"DYLD_FRAMEWORK_PATH"];
    

    // write new env for this task
    [task setEnvironment: environmentDict];
    
    NSArray *arguments = [NSArray arrayWithObjects:
                          @"-c" ,
                          [NSString stringWithFormat:@"%@", commandToRun],
                          nil];
    NSLog(@"run command: %@",commandToRun);
    [task setArguments: arguments];
    
    NSPipe *pipe;
    pipe = [NSPipe pipe];
    [task setStandardOutput: pipe];
    
    NSFileHandle *file;
    file = [pipe fileHandleForReading];
    
    [task launch];
    
    NSData *data;
    data = [file readDataToEndOfFile];
    
    NSString *output;
    output = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
    return output;
}


-(void)mediaKeyAppListChanged;
{
	if([_mediaKeyAppList count] == 0) return;
	
	/*NSLog(@"--");
	int i = 0;
	for (NSValue *psnv in _mediaKeyAppList) {
		ProcessSerialNumber psn; [psnv getValue:&psn];
		NSDictionary *processInfo = [(id)ProcessInformationCopyDictionary(
			&psn,
			kProcessDictionaryIncludeAllInformationMask
		) autorelease];
		NSString *bundleIdentifier = [processInfo objectForKey:(id)kCFBundleIdentifierKey];
		NSLog(@"%d: %@", i++, bundleIdentifier);
	}*/
	
    ProcessSerialNumber mySerial, topSerial;
	GetCurrentProcess(&mySerial);
	[[_mediaKeyAppList objectAtIndex:0] getValue:&topSerial];

	Boolean same;
	OSErr err = SameProcess(&mySerial, &topSerial, &same);
	[self setShouldInterceptMediaKeyEvents:(err == noErr && same)];	

}
-(void)appIsNowFrontmost:(ProcessSerialNumber)psn;
{
	NSValue *psnv = [NSValue valueWithBytes:&psn objCType:@encode(ProcessSerialNumber)];
	
	NSDictionary *processInfo = [(id)ProcessInformationCopyDictionary(
		&psn,
		kProcessDictionaryIncludeAllInformationMask
	) autorelease];
	NSString *bundleIdentifier = [processInfo objectForKey:(id)kCFBundleIdentifierKey];

	NSArray *whitelistIdentifiers = [[NSUserDefaults standardUserDefaults] arrayForKey:kMediaKeyUsingBundleIdentifiersDefaultsKey];
	if(![whitelistIdentifiers containsObject:bundleIdentifier]) return;

	[_mediaKeyAppList removeObject:psnv];
	[_mediaKeyAppList insertObject:psnv atIndex:0];
	[self mediaKeyAppListChanged];
}
-(void)appTerminated:(ProcessSerialNumber)psn;
{
	NSValue *psnv = [NSValue valueWithBytes:&psn objCType:@encode(ProcessSerialNumber)];
	[_mediaKeyAppList removeObject:psnv];
	[self mediaKeyAppListChanged];
}

static pascal OSStatus appSwitched (EventHandlerCallRef nextHandler, EventRef evt, void* userData)
{
	SPMediaKeyTap *self = (id)userData;

    ProcessSerialNumber newSerial;
    GetFrontProcess(&newSerial);
	
	[self appIsNowFrontmost:newSerial];
		
    return CallNextEventHandler(nextHandler, evt);
}

static pascal OSStatus appTerminated (EventHandlerCallRef nextHandler, EventRef evt, void* userData)
{
	SPMediaKeyTap *self = (id)userData;
	
	ProcessSerialNumber deadPSN;

	GetEventParameter(
		evt, 
		kEventParamProcessID, 
		typeProcessSerialNumber, 
		NULL, 
		sizeof(deadPSN), 
		NULL, 
		&deadPSN
	);

	
	[self appTerminated:deadPSN];
    return CallNextEventHandler(nextHandler, evt);
}

@end
