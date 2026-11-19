import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Storage seam for the transcript windows; tests replace it with a temp dir.
final transcriptCacheDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => () async => Directory('${(await getApplicationSupportDirectory()).path}/transcript-cache'),
);

/// The last visible window of recent conversations: opening one again paints
/// it before the Host syncs, then the snapshot replaces it.
final transcriptCacheProvider = FutureProvider<TranscriptCache>((ref) async {
  final directory = ref.watch(transcriptCacheDirectoryProvider);
  return TranscriptCache(directory: await directory());
});
