

#import "PTTorrentStreamer.h"
#import <Foundation/Foundation.h>
#import <string>
#import <libtorrent/bencode.hpp>
#import "../Security/CocoaSecurity.h"
#import "../Resources/NSString+Localization.h"
#import "PTTorrentStreamer+Protected.h"
#import <GCDWebServer.h>
#import "PTTorrentsSession.h"
#import "PTTorrentsSession+Protected.h"
#import "PTSize.h"

#define PIECE_DEADLINE_MILLIS 100

NSNotificationName const PTTorrentStatusDidChangeNotification = @"com.popcorntimetv.popcorntorrent.status.change";


using namespace libtorrent;

@implementation PTTorrentStreamer

- (instancetype)init {
    self = [super init];
    if (self) {
        selectedFileIndex = -1;
        self.session = [PTTorrentsSession sharedSession];
        [self setupSession];
    }
    return self;
}

- (PTSize *)fileSize {
    return [PTSize sizeWithLongLong:_requiredSpace];
}

- (PTSize *)totalDownloaded {
    return [PTSize sizeWithLongLong:_totalDownloaded];
}


+ (NSString *)downloadDirectory {
    NSString *downloadDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Downloads"];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:downloadDirectory]) {
        NSError *error;
        [[NSFileManager defaultManager] createDirectoryAtPath:downloadDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error];
        if (error) return nil;
    }
    
    return downloadDirectory;
}

- (void)setupSession {
    _torrentHandle = libtorrent::torrent_handle();
    firstPiece = libtorrent::piece_index_t(-1);
    endPiece = libtorrent::piece_index_t(0);
    lastFilePiece = libtorrent::piece_index_t(0);
    
    _requestedRangeInfo = [[NSMutableDictionary alloc] init];
    
    _status = torrent_status();
    if(self.mediaServer == nil)self.mediaServer = [[GCDWebServer alloc] init];
    
}

- (void)startStreamingFromMultiTorrentFileOrMagnetLink:(NSString *)filePathOrMagnetLink
                                  progress:(PTTorrentStreamerProgress)progress
                               readyToPlay:(PTTorrentStreamerReadyToPlay)readyToPlay
                                   failure:(PTTorrentStreamerFailure)failure
                                    selectFileToStream:(PTTorrentStreamerSelection)callback{
    self.selectionBlock = callback;
    [self startStreamingFromFileOrMagnetLink:filePathOrMagnetLink
                               directoryName:nil
                                    progress:progress
                                 readyToPlay:readyToPlay
                                     failure:failure];
    
}

- (void)startStreamingFromFileOrMagnetLink:(NSString *)filePathOrMagnetLink
                             directoryName:(NSString * _Nullable)directoryName
                                  progress:(PTTorrentStreamerProgress)progress
                               readyToPlay:(PTTorrentStreamerReadyToPlay)readyToPlay
                                   failure:(PTTorrentStreamerFailure)failure {
    
    
    [self startStreamingFromFileOrMagnetLink:filePathOrMagnetLink
                               directoryName:directoryName
                                    progress:progress
                                 readyToPlay:readyToPlay
                                     failure:failure
                                  fastResume:true];
}

- (void)startStreamingFromFileOrMagnetLink:(NSString *)filePathOrMagnetLink
                             directoryName:(NSString * _Nullable)directoryName
                                  progress:(PTTorrentStreamerProgress)progress
                               readyToPlay:(PTTorrentStreamerReadyToPlay)readyToPlay
                                   failure:(PTTorrentStreamerFailure)failure
                                fastResume:(Boolean)fastResume {

    self.progressBlock = progress;
    self.readyToPlayBlock = readyToPlay;
    self.failureBlock = failure;
    
    error_code ec;
    add_torrent_params tp;
    
    NSString *MD5String = nil;
    
    if ([filePathOrMagnetLink hasPrefix:@"magnet"]) {
        NSString *magnetLink = [[filePathOrMagnetLink stringByRemovingPercentEncoding] stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];

        tp = parse_magnet_uri(std::string([magnetLink UTF8String]));//std::string([magnetLink UTF8String]);
        
        MD5String = [CocoaSecurity md5:magnetLink].hexLower;
    } else {
        NSString *filePath = filePathOrMagnetLink;
        NSError *error;
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            NSData *fileData = [NSData dataWithContentsOfFile:filePath];
            MD5String = [CocoaSecurity md5WithData:fileData].hexLower;
            std::shared_ptr<torrent_info> ti1 = std::make_shared<torrent_info>([filePathOrMagnetLink UTF8String], ec);
            tp.ti = ti1;
            if (ec) {
                error = [[NSError alloc] initWithDomain:@"com.popcorntimetv.popcorntorrent.error" code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithCString:ec.message().c_str() encoding:NSUTF8StringEncoding]}];
            }
            int index = [self selectedFileIndexInTorrentWithTorrentInfo:tp.ti];
            MIN_PIECES = ((tp.ti->files().file_size(libtorrent::file_index_t(index)) * 0.03)/tp.ti->piece_length());
        } else {
            error = [[NSError alloc] initWithDomain:@"com.popcorntimetv.popcorntorrent.error" code:-2 userInfo:@{NSLocalizedDescriptionKey: [NSString localizedStringWithFormat:@"File doesn't exist at path: %@".localizedString, filePath]}];
        }
        
        if (error) {
            if (failure) failure(error);
            return [self cancelStreamingAndDeleteData:NO];
        }
    }
    
    //construct the folder path for downloads
    NSString *pathComponent = directoryName != nil ? directoryName : [MD5String substringToIndex:16];
    
    NSString *basePath = [[self class] downloadDirectory];
    
    if (!basePath) {
        NSError *error = [NSError errorWithDomain:@"com.popcorntimetv.popcorntorrent.error" code:-412 userInfo:@{NSLocalizedDescriptionKey: @"Could not create download directory".localizedString}];
        if (failure) failure(error);
        return [self cancelStreamingAndDeleteData:NO];
    }
    
    Boolean didTryFastResume = false;
    
    _savePath = [basePath stringByAppendingPathComponent:pathComponent];
    //create folder for torrents
    if (![[NSFileManager defaultManager] fileExistsAtPath:_savePath]) {
        NSError *error;
        [[NSFileManager defaultManager] createDirectoryAtPath:self.savePath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error];
        //if we cannot create folder clear all data and exit
        if (error) {
            if (failure) failure(error);
            return [self cancelStreamingAndDeleteData:NO];
        }
    } else if ([filePathOrMagnetLink hasPrefix:@"magnet"] && fastResume){
        //if folder exists already and we are loading a magnet search for resume file
        [self.session tryToResumeTorrentParams:&tp atPath:_savePath];
        didTryFastResume = true;
    }
    
    tp.save_path = std::string([self.savePath UTF8String]);
    // tp.storage_mode = storage_mode_allocate;
    
    NSError *error;
    _torrentHandle = [self.session addTorrent:self params:tp error:&error];
    
    // torrent exists, give it a new session, so there is no interference
    if (error && error.code == -2) {
        error = nil;
        self.session = [[PTTorrentsSession alloc] init];
        self.deleteOnlyDownloadedFile = YES;
        PTTorrentStreamer *existing = [[PTTorrentsSession sharedSession] torrentStreamerForTorrentHandle:_torrentHandle];
        existing.deleteOnlyDownloadedFile = YES;
        _torrentHandle = [self.session addTorrent:self params:tp error:&error];
    }
    
    if (error) {
        if (didTryFastResume) {
            // retry streaming without fast resume, aka start from scratch
            [[NSFileManager defaultManager] removeItemAtPath:self.savePath error:nil];
            [self cancelStreamingAndDeleteData:YES];
            [self startStreamingFromFileOrMagnetLink:filePathOrMagnetLink
                                       directoryName:directoryName
                                            progress:progress
                                         readyToPlay:readyToPlay
                                             failure:failure];
        } else {
            
            if (failure) failure(error);
            [self cancelStreamingAndDeleteData:NO];
        }
        return;
    }
    
    if (![filePathOrMagnetLink hasPrefix:@"magnet"] || _torrentHandle.status().has_metadata) {
        [self metadataReceivedAlert:_torrentHandle];
    }
}

- (void)handleTorrentError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.failureBlock) self.failureBlock(error);
        [self cancelStreamingAndDeleteData:NO];
    });
}

#pragma mark - Fast Forward


- (BOOL)fastForwardTorrentForRange:(NSRange)range
{
    auto torrent =  _torrentHandle;
    auto ti = torrent.torrent_file();
        
    //find the torrent piece corresponding to the requested piece of the movie
    auto index = file_index_t([self selectedFileIndexInTorrent:torrent]);
    int64_t fileSize = ti->files().file_size(index);
    // int64_t forwardRange = range.length > fileSize ? fileSize - 1 : range.location + range.length;
    int length = range.length > INT_MAX ? INT_MAX : int(range.length);
    peer_request request = ti->map_file(index, range.location, length);
        
    //set first and last pieces
    auto startPiece = request.piece;
    auto finalPiece = startPiece; // + libtorrent::piece_index_t(MIN_PIECES - 1);
    for (int i = 0; i < MIN_PIECES - 1; i++) {
        finalPiece++;
        
        //check if we are over the total pieces of the selected file
        if (finalPiece > lastFilePiece) {
            finalPiece = lastFilePiece;
            break;
        }
    }
    
    // when video starts, we already have enough pieces downloaded so video ca start imediately
    if (startPiece <= piece_index_t(6)) {
        return YES;
    }
    
    //set global variables
    firstPiece = startPiece;
    endPiece = finalPiece;
    NSLog(@"fast forwarding to new start piece: %d", (int)startPiece);
    
    //if we already have the requested part of the movie return immediately
    for(auto j = startPiece; j <= finalPiece; j++){
        if (!torrent.have_piece(j)) {
            break;
        } else if (j==finalPiece) {
            return YES;
        }
    }
    
    NSLog(@"new start piece missing, downloading...");
    //take control of the array from all of the other threads that might be accessing it
    mtx.lock();
    required_pieces.clear(); //clear all the pieces we wanted to download previously
    mtx.unlock();
    
    //start to download the requested part of the movie
    [self prioritizeNextPieces:torrent];
    
    return NO;
    
}


- (void)cancelStreamingAndDeleteData:(BOOL)deleteData {
    [self.session removeTorrent:self];
    
    required_pieces.clear();
    required_pieces.shrink_to_fit();
    
    [self.requestedRangeInfo removeAllObjects];
    _status = torrent_status();
    
    self.progressBlock = nil;
    self.readyToPlayBlock = nil;
    self.failureBlock = nil;
    
    if (self.mediaServer.isRunning) [self.mediaServer stop];
    [self.mediaServer removeAllHandlers];
    
    firstPiece = libtorrent::piece_index_t(-1);
    endPiece = libtorrent::piece_index_t(0);
    
    self.streaming = NO;
    _torrentStatus = (PTTorrentStatus){0, 0, 0, 0, 0, 0};
    _isFinished = false;
    
    if (deleteData) {
        if (self.deleteOnlyDownloadedFile) {
            NSString *filePath = [self.savePath stringByAppendingPathComponent:_fileName];
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        } else {
            // delete whole directory
            [[NSFileManager defaultManager] removeItemAtPath:self.savePath error:nil];
        }
        _savePath = nil;
        _fileName = nil;
        _requiredSpace = 0;
        _totalDownloaded = 0;
        [self setupSession];
    }
}

- (void)prioritizeNextPieces:(torrent_handle)th {
    piece_index_t next_required_piece = piece_index_t(0);
    
    // if (firstPiece != piece_index_t(-1)) {
    //     next_required_piece = firstPiece;
    // } else if (required_pieces.size() > 0) {
    //     next_required_piece = required_pieces[MIN_PIECES - 1];
    //     next_required_piece++;
    // }

    if (firstPiece != piece_index_t(-1)) {
        next_required_piece = firstPiece;
    } else if (!required_pieces.empty() && required_pieces.size() >= MIN_PIECES) {
        next_required_piece = required_pieces[MIN_PIECES - 1];
        next_required_piece++;
    }
    
    firstPiece = libtorrent::piece_index_t(-1);
    
    mtx.lock();
    
    required_pieces.clear();
    
    auto piece_priorities = th.get_piece_priorities();
    th.clear_piece_deadlines();//clear all deadlines on all pieces before we set new ones
    std::fill(piece_priorities.begin(), piece_priorities.end(), low_priority);
    th.prioritize_pieces(piece_priorities);
    
    for (int i = 0; i < MIN_PIECES; i++) {
        if (next_required_piece <= lastFilePiece) {
            th.piece_priority(next_required_piece, top_priority);
            th.set_piece_deadline(next_required_piece, PIECE_DEADLINE_MILLIS, torrent_handle::alert_when_available);
            required_pieces.push_back(next_required_piece);
            next_required_piece++;
        }
    }

    mtx.unlock();
}

- (void)processTorrent:(torrent_handle)th {
    _status = th.status();
    if ([self isStreaming]) return;
    
    if (self.readyToPlayBlock) {
        self.streaming = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startWebServerAndPlay];
        });
    }
}

- (void)startWebServerAndPlay {
    __block NSURL *fileURL = [NSURL fileURLWithPath:[self.savePath stringByAppendingPathComponent:_fileName]];
    __weak __typeof__(self) weakSelf = self;
    NSLog(@"file to be streamed is %@",[self.savePath stringByAppendingPathComponent:_fileName]);
    [self.mediaServer addDefaultHandlerForMethod:@"GET" requestClass:[GCDWebServerRequest class] asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
        GCDWebServerFileResponse *response = [[GCDWebServerFileResponse alloc] init];
        
        if (request.hasByteRange) {
            response = [[GCDWebServerFileResponse alloc]initWithFile:fileURL.relativePath byteRange:request.byteRange];
        } else {
            response = [[GCDWebServerFileResponse alloc]initWithFile:fileURL.relativePath];
        }
        if (response == nil){
            GCDWebServerErrorResponse *newResponse = [GCDWebServerErrorResponse responseWithStatusCode:416];
            [response setValue:[NSString stringWithFormat:@"*/%lu",(unsigned long)request.byteRange.location] forAdditionalHeader:@"Content-Range"];
            completionBlock(newResponse);
            return;
        }
        [response setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
        [response setValue:@"Content-Type" forAdditionalHeader:@"Access-Control-Expose-Headers"];
        
        if (!weakSelf.isFinished) {
            //if we have the parts downloaded already ready to go we deliver them below
            if ([weakSelf fastForwardTorrentForRange:request.byteRange]) {
                completionBlock(response);
            } else {
                //we now store the response and the completionBlock inside the requestedRangeInfo dictionary in order to retrieve it when we have downloaded the required pieces successfully and send the response at that time
                [weakSelf.requestedRangeInfo setObject:response forKey:@"response"];
                [weakSelf.requestedRangeInfo setObject:completionBlock forKey:@"completionBlock"];
            }
        } else {
            completionBlock(response);
        }
    }];
    
    NSMutableDictionary* options = [NSMutableDictionary dictionary];
    NSInteger port = 50321;
    [options setObject:[NSNumber numberWithInteger:port] forKey:GCDWebServerOption_Port];
    NSError *error;

    while (![self.mediaServer startWithOptions:options error:&error]) {
        port++;
        [options setObject:[NSNumber numberWithInteger:port] forKey:GCDWebServerOption_Port];

        /// failed to start webserver
        if (port > 50341) {
            if (_failureBlock) _failureBlock(error);
            [self cancelStreamingAndDeleteData:NO];
            return;
        }
    }
    
    __block NSURL *serverURL = nil; // ios now requires permission to access local network// self.mediaServer.serverURL;
    
    if (serverURL == nil) // `nil` when device is on cellular network.
    {
        serverURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://0.0.0.0:%i/", (int)self.mediaServer.port]];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.readyToPlayBlock) weakSelf.readyToPlayBlock(serverURL, fileURL);
    });
}


- (int)selectedFileIndexInTorrent:(torrent_handle)th {
    std::shared_ptr<const torrent_info> ti = th.torrent_file();
    return [self selectedFileIndexInTorrentWithTorrentInfo:ti];
}

- (int)selectedFileIndexInTorrentWithTorrentInfo:(std::shared_ptr<const torrent_info>)ti {
    if (selectedFileIndex != -1) {
        return selectedFileIndex;
    }

    auto files = ti->files();
    NSMutableArray* file_names = [[NSMutableArray alloc] init];
    NSMutableArray* file_sizes = [[NSMutableArray alloc] init];
    for (int i=0; i<ti->num_files(); i++) {
        [file_names addObject:[NSString stringWithFormat:@"%s", files.file_name(file_index_t(i)).to_string().c_str()]];
        [file_sizes addObject:[NSNumber numberWithLong: files.file_size(file_index_t(i))]];
    }

    selectedFileIndex = self.selectionBlock([file_names copy], [file_sizes copy]);
    return selectedFileIndex;
}

#pragma mark - Alerts

- (void)metadataReceivedAlert:(torrent_handle)th {
    _requiredSpace = th.status().total_wanted;
    NSURL* savePathURL = [NSURL fileURLWithPath:self.savePath];
    NSDictionary *results = [savePathURL resourceValuesForKeys:@[NSURLVolumeAvailableCapacityKey] error:nil];
    NSNumber *availableSpace = results[NSURLVolumeAvailableCapacityKey];//get available space on device
    
    int selectedIndex = [self selectedFileIndexInTorrent:th];
    file_index_t file_index = file_index_t(selectedIndex);
    
    auto file_priorities = th.get_file_priorities();
    std::fill(file_priorities.begin(), file_priorities.end(), dont_download);
    file_priorities[selectedIndex] = top_priority;
    th.prioritize_files(file_priorities);
    
    auto ti = th.torrent_file();
    int64_t file_size = ti->files().file_size(file_index);
    std::string path = ti->files().file_path(file_index);
    _fileName = [NSString stringWithCString:path.c_str() encoding:NSUTF8StringEncoding];
    NSString *filePath = [self.savePath stringByAppendingPathComponent:_fileName];
    int64_t requiredSize = file_size;

    // check if file already downloaded to ignore used space, so it will not be downloaded again from scratch
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
        long long fileSize = [[fileAttributes objectForKey:NSFileSize] longLongValue];
        requiredSize -= fileSize;
    }

    if (requiredSize > availableSpace.longLongValue) {
        PTSize *fileSize = [PTSize sizeWithLongLong: file_size];
        NSString *description = [NSString localizedStringWithFormat:@"There is not enough space to download the torrent. Please clear at least %@ and try again.".localizedString, fileSize.stringValue];
        NSError *error = [[NSError alloc] initWithDomain:@"com.popcorntimetv.popcorntorrent.error" code:-4 userInfo:@{NSLocalizedDescriptionKey: description}];
        [self handleTorrentError:error];
        return;
    }

    [self updateAndMonitorTorrentProgress];
    
    // file already downloaded
    if (_isFinished) {
        [self torrentFinishedAlert:th];
        return;
    }
    
    // download first pieces
    MIN_PIECES = (ti->files().file_size(file_index) * 0.03) / ti->piece_length();
    MIN_PIECES = std::min(MIN_PIECES, 20);
    NSLog(@"min pieces: %d", MIN_PIECES);
    piece_index_t first_piece = ti->map_file(file_index, 0, 0).piece;
    NSLog(@"first piece: %d", (int)first_piece);
    for (int i = 0; i < MIN_PIECES; i++) {
        required_pieces.push_back(first_piece);
        first_piece++;
    }
    
    // download last pieces
    piece_index_t last_piece = ti->map_file(file_index, file_size - 1, 0).piece;
    NSLog(@"last piece: %d", (int)last_piece);
    lastFilePiece = last_piece;
    int maxEndPieces = MIN_PIECES <= 6 ? 1 : 2;
    for (int i = 0; i < maxEndPieces; i++) {
        required_pieces.push_back(last_piece);
        last_piece--;
    }

    // don't download intermediate pieces when streaming starts
    piece_index_t piece = first_piece;
    do {
        th.piece_priority(piece, low_priority);
        piece++;
    } while (piece <= last_piece);
    
    th.clear_piece_deadlines();
    for (piece_index_t piece : required_pieces) {
        th.piece_priority(piece, top_priority);
        th.set_piece_deadline(piece, PIECE_DEADLINE_MILLIS, torrent_handle::alert_when_available);
    }
}

- (void)updateAndMonitorTorrentProgress {
    if (!_progressBlock || !_torrentHandle.is_valid() || _status.is_finished) {
        return;
    }

    _status = _torrentHandle.status();
    _torrentStatus = {
        _torrentStatus.bufferingProgress,
        _status.progress,
        _status.download_rate,
        _status.upload_rate,
        _status.num_seeds,
        _status.num_peers
    };
    _totalDownloaded = _status.total_wanted_done;
    _isFinished = _status.is_finished;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (_progressBlock) _progressBlock(_torrentStatus);
        [[NSNotificationCenter defaultCenter] postNotificationName:PTTorrentStatusDidChangeNotification object:self];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self updateAndMonitorTorrentProgress];
    });
}

- (void)pieceFinishedAlert:(torrent_handle)th forPieceIndex:(piece_index_t)index {
    NSLog(@"downloaded piece: %d", (int)index);
    _status = th.status();
    
    int requiredPiecesDownloaded = 0;
    BOOL allRequiredPiecesDownloaded = YES;
    
    auto copyRequired(required_pieces);
    
    for (piece_index_t piece: copyRequired) {
        if (th.have_piece(piece) == false) {
            allRequiredPiecesDownloaded = NO;
        }else{
            requiredPiecesDownloaded++;
        }
    }
    
    int requiredPieces = (int)copyRequired.size();
    float bufferingProgress = 1.0 - (requiredPieces - requiredPiecesDownloaded)/(float)requiredPieces;
    _torrentStatus = {
        bufferingProgress,
        _status.progress,
        _status.download_rate,
        _status.upload_rate,
        _status.num_seeds,
        _status.num_peers
    };
    
    _totalDownloaded = _status.total_wanted_done;
    _isFinished = _status.is_finished;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_progressBlock) _progressBlock(_torrentStatus);
        [[NSNotificationCenter defaultCenter] postNotificationName:PTTorrentStatusDidChangeNotification object:self];
    });
    
    
    
    if (allRequiredPiecesDownloaded) {
        if (th.have_piece(endPiece) && self.requestedRangeInfo.count > 0) {
            GCDWebServerFileResponse *response = [self.requestedRangeInfo objectForKey:@"response"];
            GCDWebServerCompletionBlock completionBlock = [self.requestedRangeInfo objectForKey:@"completionBlock"];
            [self.requestedRangeInfo removeAllObjects];
            completionBlock(response);
        }
        if (MIN_PIECES == 0) {
            [self metadataReceivedAlert:th];
        }
        [self prioritizeNextPieces:th];
        [self processTorrent:th];
    }
}

- (void)torrentFinishedAlert:(torrent_handle)th {
    [self processTorrent:th];
    
    _torrentStatus = {
        1, 1,
        _status.download_rate,
        _status.upload_rate,
        _status.num_seeds,
        _status.num_peers
    };
    
    _totalDownloaded = _status.total_wanted_done;
    _isFinished = _status.is_finished;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_progressBlock) _progressBlock(_torrentStatus);
        [[NSNotificationCenter defaultCenter] postNotificationName:PTTorrentStatusDidChangeNotification object:self];
    });
    
    [self.session removeTorrent:self];
    // Remove the torrent when its finished
    // th.pause(torrent_handle::graceful_pause);
}

@end

