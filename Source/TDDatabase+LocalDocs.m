//
//  TDDatabase+LocalDocs.m
//  TouchDB
//
//  Created by Jens Alfke on 1/10/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "TDDatabase+LocalDocs.h"
#import "TDRevision.h"
#import "TDBody.h"
#import "TDInternal.h"

#import "FMDatabase.h"


@implementation TDDatabase (LocalDocs)


- (TDRevision*) getLocalDocumentWithID: (NSString*)docID 
                            revisionID: (NSString*)revID
{
    TDRevision* result = nil;
    FMResultSet *r = [_fmdb executeQuery: @"SELECT revid, json FROM localdocs WHERE docid=?",docID];
    if ([r next]) {
        NSString* gotRevID = [r stringForColumnIndex: 0];
        if (revID && !$equal(revID, gotRevID))
            return nil;
        NSData* json = [r dataNoCopyForColumnIndex: 1];
        NSMutableDictionary* properties;
        if (json.length==0 || (json.length==2 && memcmp(json.bytes, "{}", 2)==0))
            properties = $mdict();      // workaround for issue #44
        else {
            properties = [TDJSON JSONObjectWithData: json
                                            options:TDJSONReadingMutableContainers
                                              error: nil];
            if (!properties)
                return nil;
        }
        [properties setObject: docID forKey: @"_id"];
        [properties setObject: gotRevID forKey: @"_rev"];
        result = [[[TDRevision alloc] initWithDocID: docID revID: gotRevID deleted:NO] autorelease];
        result.properties = properties;
    }
    [r close];
    return result;
}


- (TDRevision*) putLocalRevision: (TDRevision*)revision
                  prevRevisionID: (NSString*)prevRevID
                          status: (TDStatus*)outStatus
{
    NSString* docID = revision.docID;
    if (![docID hasPrefix: @"_local/"]) {
        *outStatus = 400;
        return nil;
    }
    if (!revision.deleted) {
        // PUT:
        NSData* json = [self encodeDocumentJSON: revision];
        NSString* newRevID;
        if (prevRevID) {
            unsigned generation = [TDRevision generationFromRevID: prevRevID];
            if (generation == 0) {
                *outStatus = 400;
                return nil;
            }
            newRevID = $sprintf(@"%d-local", ++generation);
            if (![_fmdb executeUpdate: @"UPDATE localdocs SET revid=?, json=? "
                                        "WHERE docid=? AND revid=?", 
                                       newRevID, json, docID, prevRevID]) {
                *outStatus = 500;
                return nil;
            }
        } else {
            newRevID = @"1-local";
            // The docid column is unique so the insert will be a no-op if there is already
            // a doc with this ID.
            if (![_fmdb executeUpdate: @"INSERT OR IGNORE INTO localdocs (docid, revid, json) "
                                        "VALUES (?, ?, ?)",
                                   docID, newRevID, json]) {
                *outStatus = 500;
                return nil;
            }
        }
        if (_fmdb.changes == 0) {
            *outStatus = 409;
            return nil;
        }
        *outStatus = 201;
        return [[revision copyWithDocID: docID revID: newRevID] autorelease];
        
    } else {
        // DELETE:
        *outStatus = [self deleteLocalDocumentWithID: docID revisionID: prevRevID];
        return *outStatus < 300 ? revision : nil;
    }
}


- (TDStatus) deleteLocalDocumentWithID: (NSString*)docID revisionID: (NSString*)revID {
    if (!docID)
        return 400;
    if (!revID) {
        // Didn't specify a revision to delete: 404 or a 409, depending
        return [self getLocalDocumentWithID: docID revisionID: nil] ? 409 : 404;
    }
    if (![_fmdb executeUpdate: @"DELETE FROM localdocs WHERE docid=? AND revid=?", docID, revID])
        return 500;
    if (_fmdb.changes == 0)
        return [self getLocalDocumentWithID: docID revisionID: nil] ? 409 : 404;
    return 200;
}


@end
