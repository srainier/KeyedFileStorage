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

NSString* const KFKey = @"KFSKey";
NSString* const KFNeedFileNotification = @"KFSNeedFileNotification";
NSString* const KFGotFileNotification = @"KFSGotFileNotification";
NSString* const KFErrorDomain = @"KFSErrorDomain";

// NOTE: these are all hexs, some day I could & mask against
// them to determine the category of error...
const NSUInteger KFErrorBadKeyPath = 0x01;
const NSUInteger KFErrorBadData = 0x02;
const NSUInteger KFErrorFileConflict = 0x05;
const NSUInteger KFErrorCleaningUp = 0x11;
const NSUInteger KFErrorAppEnteringBackground = 0x12;
const NSUInteger KFErrorUnexpectedReadError = 0x21;
const NSUInteger KFErrorUnexpectedWriteError = 0x22;
const NSUInteger KFErrorUnexpectedCallbackError = 0x23;
const NSUInteger KFErrorNoFileForKey = 0x31;
const NSUInteger KFErrorFileExists = 0x32;
const NSUInteger KFErrorFileInUse = 0x33;
const NSUInteger KFErrorFileNotInUse = 0x34;


@interface KeyedFileStorage () {
@private
  BOOL isCreated_;
  NSURL* rootDirectory_;
  NSMutableSet* protectedFiles_;
  NSMutableSet* pendingAddDataKeys_;
  NSMutableSet* pendingDeleteDataKeys_;
  dispatch_queue_t file_queue_;
  BOOL isCleaningUpQueue_;
}

// These two methods are used to check for proper queue
// execution.
- (void) throwIfNotQueue:(dispatch_queue_t)q;
- (void) throwIfNotMainQueue;

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

// This helper method performs work of retrieving data from disk
// for the given key and returns it asynchronously, on the main
// queue, to the caller.
// Possible callbacks:
//   callback(nil, <valid data>) - Data was successfully loaded from disk.
//   callback(<error>, nil) - An unrecoverable error occurred.
//   callback(nil, nil) - No error occurred, but no data existed for the
//     given key.  A KFNeedFileNotification is sent with the key as the
//     notification's object.
//- (void) getFileDataFromDiskWithKey:(NSString*)key callback:(void (^)(NSError* error, NSData* fileData))callback;

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

- (BOOL) createWithRootDirectory:(NSURL*)rootDirectory error:(NSError**)error {
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

    // create queue
    file_queue_ = dispatch_queue_create("com.srainier.KFS", NULL);
    isCleaningUpQueue_ = NO;
    
    // Setup member objects
    protectedFiles_ = [[NSMutableSet alloc] init];
    pendingAddDataKeys_ = [[NSMutableSet alloc] init];
    pendingDeleteDataKeys_ = [[NSMutableSet alloc] init];
    
    // Mark as created
    isCreated_ = YES;
  }
  
  return directoryExists;
}

- (BOOL) createInDocumentsSubdirectoryWithName:(NSString*)name error:(NSError**)error {
  
  NSArray* directories = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
  if (1 < directories.count) {
    NSLog(@"More than one documents directories: %d, %@", directories.count, directories);
  }
  
  // pick the first - it's the user (rather than system) documents directory.
  NSURL* userDocumentsDirectory = [directories objectAtIndex:0];

  // Assemble the full path with the subdirectory.
  NSString* subdirectoryPath = [userDocumentsDirectory.relativePath stringByAppendingPathComponent:name];
  
  // Create/initialized the file store.
  return [self createWithRootDirectory:[NSURL fileURLWithPath:subdirectoryPath] error:error];
}

- (BOOL) createInCacheSubdirectoryWithName:(NSString*)name error:(NSError**)error {
  
  NSArray* directories = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask];
  if (1 < directories.count) {
    NSLog(@"More than one caches directories: %d, %@", directories.count, directories);
  }
  
  // pick the first - it's the user (rather than system) caches directory.
  NSURL* userCachesDirectory = [directories objectAtIndex:0];
  
  // Assemble the full path with the subdirectory.
  NSString* subdirectoryPath = [userCachesDirectory.relativePath stringByAppendingPathComponent:name];
  
  // Create/initialized the file store.
  return [self createWithRootDirectory:[NSURL fileURLWithPath:subdirectoryPath] error:error];
}

- (void) cleanup {
  [self throwIfNotMainQueue];
  [self throwIfNotCreated];

  if (isCreated_) {
    // release the queue.
    isCleaningUpQueue_ = YES;
    dispatch_sync(file_queue_, ^{
      // Just wait for this to complete to guarantee the queue is empty.
    });
    dispatch_release(file_queue_);
    
    // Cleanup member objects
    rootDirectory_ = nil;
    protectedFiles_ = nil;
  }
}


- (BOOL) hasFileWithKey:(NSString*)key {
  [self throwIfNotMainQueue];
  [self throwIfNotCreated];
  
  return [[NSFileManager defaultManager] fileExistsAtPath:[[self fileUrlForKey:key] relativePath]];
}

- (BOOL) storeFile:(NSURL*)fileUrl withKey:(NSString*)key overwrite:(BOOL)overwrite error:(NSError**)error {
  [self throwIfNotMainQueue];
  [self throwIfNotCreated];

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
  [self throwIfNotMainQueue];
  [self throwIfNotCreated];
  
  NSString* newKey = [KeyedFileStorage uniqueKey];
  if ([self storeFile:fileUrl withKey:newKey overwrite:NO error:error]) {
    return newKey;
  } else {
    return nil;
  }
}

- (BOOL) deleteFileWithKey:(NSString*)key error:(NSError**)error {
  [self throwIfNotMainQueue];
  [self throwIfNotCreated];

  // Get the internal url for the key.
  NSURL* storedFileUrl = [self fileUrlForKey:key];
  
  if ([protectedFiles_ containsObject:key]) {
    // Don't delete the file if it is in use.
    if (nil != error) {
      *error = [NSError errorWithDomain:KFErrorDomain code:0 userInfo:nil];
    }
    return NO;
  }

  // Delete the file, if it exists.
  NSFileManager* fileManager = [NSFileManager defaultManager];
  if ([fileManager fileExistsAtPath:storedFileUrl.relativePath]) {
    return [fileManager removeItemAtURL:storedFileUrl error:error];
  } else {
    return YES;
  }
}

- (void) accessFileWithKey:(NSString*)key accessBlock:(void (^)(NSError *error, NSURL *storedFileUrl))accessBlock {
  [self throwIfNotMainQueue];
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
  [self throwIfNotMainQueue];
  [self throwIfNotCreated];

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
  [self throwIfNotMainQueue];
  [self throwIfNotCreated];

  // Don't allow use if file already in use.
  if ([protectedFiles_ containsObject:key]) {
    [protectedFiles_ removeObject:key];
  }

  return YES;
}

- (BOOL) hasDataWithKey:(NSString*)key {
  [self throwIfNotMainQueue];
  [self throwIfNotCreated];
  
  // Data is read/returned and deleted asyncronously, so it is not enough to just check if
  // the backing file is contained on disk.  The asynchronous operations are accounted for
  // with their keys stored in the two sets, so check for those before checking disk.
  if ([pendingDeleteDataKeys_ containsObject:key]) {
    return NO;
  } else if ([pendingAddDataKeys_ containsObject:key]) {
    return YES;
  } else {
    return [[NSFileManager defaultManager] fileExistsAtPath:[[self fileUrlForKey:key] relativePath]];
  }
}

- (BOOL) storeData:(NSData*)data withKey:(NSString*)key overwrite:(BOOL)overwrite error:(NSError**)error {
  
}


- (BOOL) storeFile:(NSURL*)fileUrl withKey:(NSString*)key overwrite:(BOOL)overwrite error:(NSError**)error {
  [self throwIfNotMainQueue];
  [self throwIfNotCreated];
  
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
  [self throwIfNotMainQueue];
  [self throwIfNotCreated];
  
  NSString* newKey = [KeyedFileStorage uniqueKey];
  if ([self storeFile:fileUrl withKey:newKey overwrite:NO error:error]) {
    return newKey;
  } else {
    return nil;
  }
}

- (NSString*) storeNewData:(NSData*)data error:(NSError**)error {
  [self throwIfNotMainQueue];
  [self throwIfNotCreated];
  
  NSString* newKey = [KeyedFileStorage uniqueKey];
  if ([self storeData:data withKey:newKey overwrite:NO error:error]) {
    return newKey;
  } else {
    return nil;
  }
}

- (BOOL) deleteDataWithKey:(NSString*)key error:(NSError**)error;
- (void) dataWithKey:(NSString*)key callback:(void (^)(NSError* error, NSData* data))callback;
- (void) dataWithKey:(NSString*)key queue:(dispatch_queue_t)queue callback:(void (^)(NSError* error, NSData* data))callback;


//
// Helpers
//
- (void) throwIfNotQueue:(dispatch_queue_t)q {
  if (q != dispatch_get_current_queue()) {
    NSAssert(q != dispatch_get_current_queue(), @"Input queue should be current queue");
    @throw [NSException exceptionWithName:@"Queue Check Fail" reason:@"Incorrect Queue" userInfo:nil];
  }
}

- (void) throwIfNotMainQueue {
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

/*
- (void) getFileDataFromDiskWithKey:(NSString*)key callback:(void (^)(NSError* error, NSData* fileData))callback {
  if (isCleaningUpQueue_) {
    // Return that file access is no longer allowed.
    callback([NSError errorWithDomain:KFErrorDomain code:KFErrorCleaningUp userInfo:nil], nil);
    
  } else {
    
    // Protect the background queue with a background task, so that
    // sudden termination doesn't kill a task in process.
    UIBackgroundTaskIdentifier backgroundID = 
    [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
      // If the background task is taking too long, I presume either the queued block
      // won't get executed (ok) or the executing block will be forceably terminated.
      // I think the forceable termination is OK because we aren't mutating any data.
      callback([NSError errorWithDomain:KFErrorDomain code:KFErrorAppEnteringBackground userInfo:nil], nil);
    }];
    
    if (UIBackgroundTaskInvalid == backgroundID) {
      // Couldn't get a background ID, so don't even try to retrieve from disk.
      callback([NSError errorWithDomain:KFErrorDomain code:KFErrorAppEnteringBackground userInfo:nil], nil);
      
    } else {
      
      dispatch_async(file_queue_, ^{

        @try {
          // Get ready to look for the file.
          NSFileManager* fm = [NSFileManager defaultManager];
          BOOL isDirectory = YES;
          NSURL* fileUrl = [self fileUrlForKey:key];
          
          if ([fm fileExistsAtPath:fileUrl.path isDirectory:&isDirectory]) {
            if (isDirectory) {
              // File exists, but it's a directory.  That's bad and probably means the
              // user entered a bad key.  Return an error.
              dispatch_async(dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] endBackgroundTask:backgroundID];
                callback([NSError errorWithDomain:KFErrorDomain code:KFErrorFileConflict userInfo:nil], nil);
              });
              
            } else {
              // Load the file data into memory in the background.
              NSData* fileData = nil;
              @try {
                fileData = [NSData dataWithContentsOfURL:fileUrl];
              }
              @catch (NSException *exception) {
                // Just catching
              }
              
              // Return the file data to the main queue.
              dispatch_async(dispatch_get_main_queue(), ^{                
                [[UIApplication sharedApplication] endBackgroundTask:backgroundID];
                
                if (nil != fileData) {
                  // Cache the file data
                  [cachedFileData_ setObject:fileData forKey:key];
                  
                  // Give the data to the user.
                  callback(nil, fileData);
                  
                } else {
                  callback([NSError errorWithDomain:KFErrorDomain code:KFErrorBadData userInfo:nil], nil);
                }
              });
            }
          } else {
            // Nothing exists for the key.  Send a notification to whomever is listening that
            // data was requested for the given key, and that it needs to be set into
            // here so that the requester can get it... eventually.
            dispatch_async(dispatch_get_main_queue(), ^{
              @try {
                // Callback - no data, but not an error, means data request is being sent.
                callback(nil, nil);
                // Send data request
                [[NSNotificationCenter defaultCenter] postNotificationName:KFNeedFileNotification object:key];
              }
              @catch (NSException *exception) {
                callback([NSError errorWithDomain:KFErrorDomain code:KFErrorUnexpectedCallbackError userInfo:nil], nil);
              }
              @finally {
                [[UIApplication sharedApplication] endBackgroundTask:backgroundID];
              }
            });
          }      
        }
        @catch (NSException *exception) {
          callback([NSError errorWithDomain:KFErrorDomain code:KFErrorUnexpectedReadError userInfo:nil], nil);
        }
        @finally {
          [[UIApplication sharedApplication] endBackgroundTask:backgroundID];
        }
      });
    }
  }
}
 */

@end
