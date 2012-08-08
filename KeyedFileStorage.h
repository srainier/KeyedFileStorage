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

extern NSString* const KFKey;
extern NSString* const KFErrorDomain;

extern const NSUInteger KFErrorBadKeyPath;
extern const NSUInteger KFErrorBadData;
extern const NSUInteger KFErrorFileConflict;
extern const NSUInteger KFErrorCleaningUp;
extern const NSUInteger KFErrorAppEnteringBackground;
extern const NSUInteger KFErrorUnexpectedReadError;
extern const NSUInteger KFErrorUnexpectedWriteError;
extern const NSUInteger KFErrorUnexpectedCallbackError;

extern const NSUInteger KFErrorNoFileForKey;
extern const NSUInteger KFErrorFileExists;
extern const NSUInteger KFErrorFileInUse;
extern const NSUInteger KFErrorFileNotInUse;


@interface KeyedFileStorage : NSObject

+ (KeyedFileStorage*) defaultStorage;
+ (NSString*) uniqueKey;

- (BOOL) createWithRootDirectory:(NSURL*)rootDirectory error:(NSError**)error;
- (BOOL) createInDocumentsSubdirectoryWithName:(NSString*)name error:(NSError**)error;
- (void) cleanup;

// Moves file into storage synchronously
// Throws if not overwrite and file exists.
- (BOOL) hasFileWithKey:(NSString*)key;

- (BOOL) storeFile:(NSURL*)fileUrl withKey:(NSString*)key overwrite:(BOOL)overwrite error:(NSError**)error;
- (NSString*) storeNewFile:(NSURL*)fileUrl error:(NSError**)error;
- (BOOL) deleteFileWithKey:(NSString*)key error:(NSError**)error;

- (void) accessFileWithKey:(NSString*)key accessBlock:(void (^)(NSError *error, NSURL *storedFileUrl))accessBlock;
- (NSURL*) useFileWithKey:(NSString*)key error:(NSError**)error;
- (BOOL) releaseFileWithKey:(NSString*)key error:(NSError**)error;

@end
