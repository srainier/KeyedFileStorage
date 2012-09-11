//
// KeyedFileStorage.m
//
// Copyright (c) 2012 Shane Arney (srainier@gmail.com)
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
// THE SOFTWARE.

#import "KeyedFileStorage.h"

NSString* const KFErrorDomain = @"KFSErrorDomain";

@interface KeyedFileStorage () {
@private
  BOOL isCreated_;
  NSURL* rootDirectory_;
  NSMutableSet* protectedFiles_;
  dispatch_queue_t access_queue_;
  dispatch_queue_t data_file_queue_;
  BOOL isCleaningUpQueue_;
}

// These two methods are used to check for proper queue
// execution.
- (void) throwIfNotQueue:(dispatch_queue_t)q;
- (void) throwIfNotAccessQueue;

// This methods protects against attempted file access before
// the object is setup.
- (void) throwIfNotCreated;

// This method wraps the cruft code of creating an exception when
// a get/set method is called prior to this object's root directory
// being setup.
- (void) throwProtectionErrorWithMessage:(NSString*)message;

// This method creates a full file url for the given
// key.  The file url returned will always be the same
// for a given key.
- (NSURL*) fileUrlForKey:(NSString*)key;

- (void) accessDataWithKey:(NSString*)key access_block:(void (^)(NSURL*, NSError**))access_block callback:(void (^)(NSError*))callback;
- (void) storeData:(NSData*)data forKey:(NSString*)key overwrite:(BOOL)overwrite callback:(void (^)(NSError*))callback;

@end

@implementation KeyedFileStorage

+ (KeyedFileStorage*) defaultStorage {
  static KeyedFileStorage* defaultStorage = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    defaultStorage = [[KeyedFileStorage alloc] init];
  });
  return defaultStorage;
}

+ (NSString*) uniqueKey {
  CFUUIDRef theUUID = CFUUIDCreate(NULL);
  CFStringRef string = CFUUIDCreateString(NULL, theUUID);
  NSString* uniqueString = [NSString stringWithString:(__bridge NSString*)string];
  CFRelease(theUUID);
  CFRelease(string);
  
  return uniqueString;
}

+ (NSString*) uniqueKeyFromString:(NSString*)seedString {
  return [NSString stringWithFormat:@"%@_%@",
          [[KeyedFileStorage uniqueKey] substringToIndex:8],
          seedString];
}

- (BOOL) createWithRootDirectory:(NSURL*)rootDirectory error:(NSError**)error {
  return [self createWithRootDirectory:rootDirectory access_queue:dispatch_get_current_queue() error:error];
}

- (BOOL) createWithRootDirectory:(NSURL*)rootDirectory access_queue:(dispatch_queue_t)access_queue error:(NSError**)error {

  if (isCreated_) {
    [self throwProtectionErrorWithMessage:@"Already created"];
  }

  // Create directory structure
  BOOL isDirectory = NO;
  BOOL directoryExists = [[NSFileManager defaultManager] fileExistsAtPath:rootDirectory.relativePath isDirectory:&isDirectory];
  if (!directoryExists) {
    directoryExists = [[NSFileManager defaultManager] createDirectoryAtURL:rootDirectory withIntermediateDirectories:YES attributes:nil error:error];
  }
  
  if (directoryExists) {
    rootDirectory_ = rootDirectory;
    access_queue_ = access_queue;

    // create queue
    data_file_queue_ = dispatch_queue_create("com.srainier.KFS", NULL);
    isCleaningUpQueue_ = NO;
    
    // Setup member objects
    protectedFiles_ = [[NSMutableSet alloc] init];
    
    // Mark as created
    isCreated_ = YES;
  }
  
  return directoryExists;
}

- (BOOL) createInDocumentsSubdirectoryWithName:(NSString*)name error:(NSError**)error {
  return [self createInDocumentsSubdirectoryWithName:name access_queue:NULL error:error];
}

- (BOOL) createInDocumentsSubdirectoryWithName:(NSString*)name access_queue:(dispatch_queue_t)access_queue error:(NSError**)error {
  
  NSArray* directories = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
  if (1 < directories.count) {
    NSLog(@"More than one documents directories: %d, %@", directories.count, directories);
  }
  
  // pick the first - it's the user (rather than system) documents directory.
  NSURL* userDocumentsDirectory = [directories objectAtIndex:0];

  // Assemble the full path with the subdirectory.
  NSString* subdirectoryPath = [userDocumentsDirectory.relativePath stringByAppendingPathComponent:name];
  
  // Create/initialized the file store.
  return [self createWithRootDirectory:[NSURL fileURLWithPath:subdirectoryPath]
                          access_queue:(NULL == access_queue) ? dispatch_get_current_queue() : access_queue
                                 error:error];
}

- (BOOL) createInCacheSubdirectoryWithName:(NSString*)name error:(NSError**)error {
  return [self createInCacheSubdirectoryWithName:name access_queue:NULL error:error];
}

- (BOOL) createInCacheSubdirectoryWithName:(NSString*)name access_queue:(dispatch_queue_t)access_queue error:(NSError **)error{
  
  NSArray* directories = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask];
  if (1 < directories.count) {
    NSLog(@"More than one caches directories: %d, %@", directories.count, directories);
  }
  
  // pick the first - it's the user (rather than system) caches directory.
  NSURL* userCachesDirectory = [directories objectAtIndex:0];
  
  // Assemble the full path with the subdirectory.
  NSString* subdirectoryPath = [userCachesDirectory.relativePath stringByAppendingPathComponent:name];
  
  // Create/initialized the file store.
  return [self createWithRootDirectory:[NSURL fileURLWithPath:subdirectoryPath]
                          access_queue:(NULL == access_queue) ? dispatch_get_current_queue() : access_queue
                                 error:error];
}

- (void) cleanup {
  [self throwIfNotAccessQueue];
  [self throwIfNotCreated];

  if (isCreated_) {
    // release the queue.
    isCleaningUpQueue_ = YES;
    dispatch_sync(data_file_queue_, ^{
      // Just wait for this to complete to guarantee the queue is empty.
    });
    dispatch_release(data_file_queue_);
    
    // Cleanup member objects
    rootDirectory_ = nil;
    protectedFiles_ = nil;
  }
}

//
// Synchronous file access methods
//

- (BOOL) hasFileWithKey:(NSString*)key {
  [self throwIfNotAccessQueue];
  [self throwIfNotCreated];
  
  if (nil == key) {
    return NO;
  }
  
  // TODO: add a check for if the key is of an expected format.
  
  return [[NSFileManager defaultManager] fileExistsAtPath:[[self fileUrlForKey:key] relativePath]];
}

- (BOOL) storeFile:(NSURL*)fileUrl withKey:(NSString*)key overwrite:(BOOL)overwrite error:(NSError**)error {
  [self throwIfNotAccessQueue];
  [self throwIfNotCreated];

  // Verify that the input file exists.
  NSFileManager* fileManager = [NSFileManager defaultManager];
  if (![fileManager fileExistsAtPath:fileUrl.relativePath]) {
    @throw [NSException exceptionWithName:@"KFSError" reason:[NSString stringWithFormat:@"Input file %@ doesn't exist", fileUrl] userInfo:nil];
  }

  // Get the internal url for the key.
  NSURL* storedFileUrl = [self fileUrlForKey:key];

  // Check that we have permission to overwrite the file, if it exists.
  if (!overwrite && [fileManager fileExistsAtPath:storedFileUrl.relativePath]) {
    @throw [NSException exceptionWithName:@"KFSException" reason:@"File exists and overwrite set to NO" userInfo:nil];
  }
  
  // NOTE: assuming this will just work to overwrite existing files if I have write priviledges.
  return [fileManager moveItemAtURL:fileUrl toURL:storedFileUrl error:error];
}

- (NSString*) storeNewFile:(NSURL*)fileUrl error:(NSError**)error {
  return [self storeNewFile:fileUrl seedString:nil error:error];
}

- (NSString*) storeNewFile:(NSURL*)fileUrl seedString:(NSString*)seedString error:(NSError**)error {
  
  NSString* newKey = (nil == seedString) ? [KeyedFileStorage uniqueKey] : [KeyedFileStorage uniqueKeyFromString:seedString];
  if ([self storeFile:fileUrl withKey:newKey overwrite:NO error:error]) {
    return newKey;
  } else {
    return nil;
  }
}


- (BOOL) deleteFileWithKey:(NSString*)key error:(NSError**)error {
  [self throwIfNotAccessQueue];
  [self throwIfNotCreated];

  // Fail gracefully if the file is in use.
  if ([protectedFiles_ containsObject:key]) {
    // Don't delete the file if it is in use.
    if (nil != error) {
      *error = [NSError errorWithDomain:KFErrorDomain code:0 userInfo:nil];
    }
    return NO;
  }

  // Get the internal url for the key.
  NSURL* storedFileUrl = [self fileUrlForKey:key];
  
  // Delete the file, if it exists.
  NSFileManager* fileManager = [NSFileManager defaultManager];
  if ([fileManager fileExistsAtPath:storedFileUrl.relativePath]) {
    return [fileManager removeItemAtURL:storedFileUrl error:error];
  } else {
    return YES;
  }
}

- (void) accessFileWithKey:(NSString*)key accessBlock:(void (^)(NSError *error, NSURL *storedFileUrl))accessBlock {
  [self throwIfNotAccessQueue];
  [self throwIfNotCreated];

  if ([protectedFiles_ containsObject:key]) {
    // Don't delete the file if it is in use.
    accessBlock([NSError errorWithDomain:KFErrorDomain code:0 userInfo:nil], nil);
    
  } else if (![self hasFileWithKey:key]) {
    // File doesn't exist
    accessBlock([NSError errorWithDomain:KFErrorDomain code:0 userInfo:nil], nil);

  } else {
    @try {
      [protectedFiles_ addObject:key];
      accessBlock(nil, [self fileUrlForKey:key]);
    }
    @catch (NSException *exception) {
      // Not doing anything here..
    }
    @finally {
      [protectedFiles_ removeObject:key];
    }    
  }
}

- (NSURL*) useFileWithKey:(NSString*)key error:(NSError**)error {
  [self throwIfNotAccessQueue];
  [self throwIfNotCreated];

  // Fail gracefully if no such file exists.
  if (![self hasFileWithKey:key]) {
    if (nil != error) {
      *error = [NSError errorWithDomain:KFErrorDomain code:0 userInfo:nil];
    }
    return nil;
  }
  
  // Don't allow use if file already in use.
  if ([protectedFiles_ containsObject:key]) {
    if (nil != error) {
      *error = [NSError errorWithDomain:KFErrorDomain code:0 userInfo:nil];
    }
    return nil;
  }
  
  // Store the key to protect additional access to the file.
  [protectedFiles_ addObject:key];
  
  // Return the url to the stored file.
  return [self fileUrlForKey:key];
}

- (BOOL) releaseFileWithKey:(NSString*)key error:(NSError**)error {
  [self throwIfNotAccessQueue];
  [self throwIfNotCreated];

  // Don't allow use if file already in use.
  if ([protectedFiles_ containsObject:key]) {
    [protectedFiles_ removeObject:key];
  }

  return YES;
}

//
// Asynchronous data access methods.
//

- (void) storeNewData:(NSData*)data callback:(void (^)(NSError*, NSString*))callback {
  // Create a new key for the data.
  NSString* key = [KeyedFileStorage uniqueKey];
  
  // Store the data, failing if data somehow already exists.
  [self storeData:data
           forKey:key
        overwrite:NO
         callback:^(NSError * error) {
           callback(error, (nil == error) ? key : nil);
         }];
}

- (void) storeData:(NSData*)data withKey:(NSString*)key canOverwrite:(BOOL)canOverwrite callback:(void (^)(NSError*))callback {
  // Simply call the helper.
  [self storeData:data
           forKey:key
        overwrite:canOverwrite
         callback:callback];
}


- (void) deleteDataWithKey:(NSString*)key callback:(void (^)(NSError*))callback {

  [self accessDataWithKey:key access_block:^(NSURL * storedDataUrl, NSError *__autoreleasing * error) {
    
    // Remove the data file if it exists.  If it doesn't exists then that's as good as removing it.
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:storedDataUrl.relativeString]) {
      [fileManager removeItemAtURL:storedDataUrl error:error];
    }
    
  } callback:^(NSError * error) {
    callback(error);
  }];
}

- (void) dataWithKey:(NSString*)key callback:(void (^)(NSError* error, NSData* data))callback {

  // Data read in the access block will be stored here and returned via the callback
  // block, assuming everything works properly.
  __block NSData* data = nil;

  [self accessDataWithKey:key access_block:^(NSURL * storedDataUrl, NSError *__autoreleasing * error) {
    data = [NSData dataWithContentsOfURL:storedDataUrl options:NSDataReadingUncached error:error];
  } callback:^(NSError * error) {
    callback(error, (nil == error) ? data : nil);
  }];
}


//
// Helpers
//

- (void) throwIfNotQueue:(dispatch_queue_t)q {
  if (q != dispatch_get_current_queue()) {
    NSAssert(q != dispatch_get_current_queue(), @"Input queue should be current queue");
    @throw [NSException exceptionWithName:@"Queue Check Fail" reason:@"Incorrect Queue" userInfo:nil];
  }
}

- (void) throwIfNotAccessQueue {
  [self throwIfNotQueue:dispatch_get_main_queue()];
}

- (void) throwIfNotCreated {
  // Protect against the object's underlying file store not being created.
  if (!isCreated_) {
    [self throwProtectionErrorWithMessage:@"Can't access - not created"];
  }
}

- (void) throwProtectionErrorWithMessage:(NSString*)message {
  @throw [NSException exceptionWithName:@"KFS Create Failure"
                                 reason:message
                               userInfo:nil];
}

- (NSURL*) fileUrlForKey:(NSString*)key {
  if (nil == key) {
    NSLog(@"Unable to create file url for nil key");
    return nil;
  }
  
  NSInteger levels = 3;
  NSURL* fileDirectoryUrl = rootDirectory_;
  for (NSInteger level = 0; level < levels; level += 1) {
    fileDirectoryUrl = [fileDirectoryUrl URLByAppendingPathComponent:[key substringWithRange:NSMakeRange(level, 1)] isDirectory:YES];
  }
  
  NSFileManager* fileManager = [NSFileManager defaultManager];
  NSError* createError = nil;
  BOOL isDirectory = NO;
  if (![fileManager fileExistsAtPath:fileDirectoryUrl.relativePath isDirectory:&isDirectory]) {
    [fileManager createDirectoryAtURL:fileDirectoryUrl withIntermediateDirectories:YES attributes:nil error:&createError];
  } else if (!isDirectory) {
    createError = [NSError errorWithDomain:@"KFS" code:0 userInfo:0];
  }
  
  if (nil == createError && nil != fileDirectoryUrl) {
    return [fileDirectoryUrl URLByAppendingPathComponent:key];
  } else {
    return nil;
  }
}

- (void) accessDataWithKey:(NSString*)key access_block:(void (^)(NSURL*, NSError**))access_block callback:(void (^)(NSError*))callback {
  // Don't even bother if the storage hasn't been setup yet.
  [self throwIfNotCreated];

  // Enforce queue safety.
  [self throwIfNotAccessQueue];
  
  // Setup the task to run in the background.
  __block BOOL callbackPerformed = NO;
  UIBackgroundTaskIdentifier backgroundTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
    if (!callback) {
      callbackPerformed = YES;
      
      // Callback that the task failed.
      callback([NSError errorWithDomain:KFErrorDomain code:0 userInfo:nil]);
    }
  }];
  
  if (UIBackgroundTaskInvalid == backgroundTaskID) {
    // Backgrounding isn't allowed, so don't attempt access.
    // Dispatching because the interface needs all callbacks to be asynchronous.
    // Not sure if there's a conflict with backgrounding here...
    dispatch_async(access_queue_, ^{
      callback([NSError errorWithDomain:KFErrorDomain code:0 userInfo:nil]);
    });

  } else {
  
    // Create the file url for the key.  This will create the appropriate directories
    // in the path.  Also do this in the main queue so that the key doesn't have to
    // be copied to ensure immutability.
    NSURL* storedDataUrl = [self fileUrlForKey:key];
    
    // All data-file access should occur in this background queue.
    dispatch_async(data_file_queue_, ^{
      
      // Protect the access block from crashing the queue.
      NSError* error = nil;
      @try {
        access_block(storedDataUrl, &error);
      }
      @catch (NSException *exception) {
        NSLog(@"Error accessing KFS data: %@", exception.description);
        error = [NSError errorWithDomain:KFErrorDomain code:0 userInfo:nil];
      }
      
      dispatch_async(access_queue_, ^{
        if (!callbackPerformed) {
          callbackPerformed = YES;
          // Protect the callback from crashing the access queue.
          @try {
            callback(error);
          }
          @catch (NSException *exception) {
            NSLog(@"Caught error in callback: %@", exception.description);
          }
          @finally {
            // Mark that the background task has completed.
            [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskID];
          }
        }
      });
    });
  }
}

- (void) storeData:(NSData*)data forKey:(NSString*)key overwrite:(BOOL)overwrite callback:(void (^)(NSError*))callback {
  
  [self accessDataWithKey:key access_block:^(NSURL * storedDataUrl, NSError *__autoreleasing * error) {
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:storedDataUrl.relativePath] || overwrite) {
      // Write atomically so that we don't end up with garbage data.
      [data writeToURL:storedDataUrl options:NSDataWritingAtomic error:error];
      
    } else {
      if (nil != error) {
        *error = [NSError errorWithDomain:KFErrorDomain code:0 userInfo:nil];
      }
    }
    
  } callback:callback];
  
}

@end
