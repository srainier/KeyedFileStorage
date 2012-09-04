//
// KeyedFileStorage.h
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

#import <Foundation/Foundation.h>

extern NSString* const KFErrorDomain;

@interface KeyedFileStorage : NSObject

// Get a globally-shared instance.
+ (KeyedFileStorage*) defaultStorage;

// Generate a key that is guaranteed to be unique for the storage.
+ (NSString*) uniqueKey;

// All of these 'create' methods perform required initialization of a KeyedFileStorage
// object.  Storage can be created anywhere you have permission to read and write to disk,
// and there are convenience methods for putting the storage in the user's Documents
// directory (for files that should be permanent) and the user's Caches directory (for files
// that can be deleted if necessary).  KeyedFileStorage objects can only be accessed from
// a single (serial) queue, and will throw if accessed from outside the queue the store was
// created on.  You can manually specify a different access queue if you need to create the
// storage on a different queue than that which you need to access it on.
- (BOOL) createWithRootDirectory:(NSURL*)rootDirectory error:(NSError**)error;
- (BOOL) createWithRootDirectory:(NSURL*)rootDirectory access_queue:(dispatch_queue_t)access_queue error:(NSError**)error;
- (BOOL) createInDocumentsSubdirectoryWithName:(NSString*)name error:(NSError**)error;
- (BOOL) createInDocumentsSubdirectoryWithName:(NSString*)name access_queue:(dispatch_queue_t)access_queue error:(NSError**)error;
- (BOOL) createInCacheSubdirectoryWithName:(NSString*)name error:(NSError**)error;
- (BOOL) createInCacheSubdirectoryWithName:(NSString*)name access_queue:(dispatch_queue_t)access_queue error:(NSError**)error;

// Shutdown and uninitialize a store
- (void) cleanup;

// Moves file into storage synchronously
// Throws if not overwrite and file exists.
- (BOOL) hasFileWithKey:(NSString*)key;

//
// Synchronous file access methods
//
- (BOOL) storeFile:(NSURL*)fileUrl withKey:(NSString*)key overwrite:(BOOL)overwrite error:(NSError**)error;
- (NSString*) storeNewFile:(NSURL*)fileUrl error:(NSError**)error;
- (BOOL) deleteFileWithKey:(NSString*)key error:(NSError**)error;
- (void) accessFileWithKey:(NSString*)key accessBlock:(void (^)(NSError *error, NSURL *storedFileUrl))accessBlock;
- (NSURL*) useFileWithKey:(NSString*)key error:(NSError**)error;
- (BOOL) releaseFileWithKey:(NSString*)key error:(NSError**)error;

//
// Asynchronous data access methods
//
- (void) storeNewData:(NSData*)data callback:(void (^)(NSError*, NSString*))callback;
- (void) storeExistingData:(NSData*)data withKey:(NSString*)key callback:(void (^)(NSError*))callback;
- (void) deleteDataWithKey:(NSString*)key callback:(void (^)(NSError*))callback;
- (void) dataWithKey:(NSString*)key callback:(void (^)(NSError* error, NSData* data))callback;

@end
