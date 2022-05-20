import 'dart:convert';

import 'package:firebase_dart/src/database/impl/operations/tree.dart';
import 'package:firebase_dart/src/database/impl/persistence/prune_forest.dart';
import 'package:firebase_dart/src/database/impl/persistence/tracked_query.dart';
import 'package:hive/hive.dart';
import 'package:synchronized/extension.dart';

import '../data_observer.dart';
import '../tree.dart';
import '../utils.dart';
import '../treestructureddata.dart';
import 'engine.dart';

class HivePersistenceStorageEngine extends PersistenceStorageEngine {
  static const _serverCachePrefix = 'C';
  static const _trackedQueryPrefix = 'Q';
  static const _userWritesPrefix = 'W';

  late IncompleteData _serverCache;
  late IncompleteData _lastWrittenServerCache;

  IncompleteData get currentServerCache => _serverCache;

  final KeyValueDatabase database;

  HivePersistenceStorageEngine(this.database) {
    _serverCache = _lastWrittenServerCache = loadServerCache();
  }

  IncompleteData loadServerCache() {
    var keys = database.keysBetween(
      startKey: '$_serverCachePrefix:',
      endKey: '$_serverCachePrefix;',
    );

    return IncompleteData.fromLeafs({
      for (var k in keys)
        Name.parsePath(k.substring('$_serverCachePrefix:'.length)):
            TreeStructuredData.fromExportJson(database.box.get(k))
    });
  }

  @override
  void beginTransaction() {
    database.beginTransaction();
  }

  @override
  void deleteTrackedQuery(int trackedQueryId) {
    database.delete('$_trackedQueryPrefix:$trackedQueryId');
  }

  @override
  void endTransaction() {
    database.endTransaction();
  }

  @override
  List<TrackedQuery> loadTrackedQueries() {
    return [
      ...database
          .valuesBetween(
              startKey: '$_trackedQueryPrefix:',
              endKey: '$_trackedQueryPrefix;')
          .map((v) => TrackedQuery.fromJson(v))
    ]..sort((a, b) => Comparable.compare(a.id, b.id));
  }

  @override
  Map<int, TreeOperation> loadUserOperations() {
    return {
      for (var k in database.keysBetween(
          startKey: '$_userWritesPrefix:', endKey: '$_userWritesPrefix;'))
        int.parse(k.substring('$_userWritesPrefix:'.length)):
            TreeOperationX.fromJson(database.box.get(k))
    };
  }

  @override
  void overwriteServerCache(TreeOperation operation) {
    _serverCache = _serverCache.applyOperation(operation);
    _scheduleWriteToDatabase();
  }

  Future<void>? _writeToDatabaseFuture;

  void _scheduleWriteToDatabase() {
    _writeToDatabaseFuture ??=
        Future.delayed(const Duration(milliseconds: 500), () {
      if (_writeToDatabaseFuture == null) return;
      synchronized(() async {
        _writeToDatabaseFuture = null;
        await _writeToDatabase();
      });
    });
  }

  Future<void> _writeToDatabase() async {
    database.beginTransaction();
    _serverCache.forEachCompleteNode((k, v) {
      var c = _lastWrittenServerCache.child(k);
      if (c.isComplete && c.value == v) return;
      var p = k.join('/');
      database.deleteAll(database.keysBetween(
        startKey: '$_serverCachePrefix:$p/',
        endKey: '$_serverCachePrefix:${p}0',
      ));

      // we will read back the data as if it were ordered/filtered with default, so we should also write it like that
      assert(v.filter == const QueryFilter());

      database.put('$_serverCachePrefix:$p/', v.toJson(true));
    });
    await database.endTransaction();
  }

  @override
  void pruneCache(Path<Name> root, PruneForest pruneForest) {
    database._verifyInsideTransaction();

    _serverCache.forEachCompleteNode((absoluteDataPath, value) {
      assert(root == absoluteDataPath || !absoluteDataPath.isDescendantOf(root),
          'Pruning at $root but we found data higher up.');
      if (root.isDescendantOf(absoluteDataPath)) {
        final dataPath = absoluteDataPath.skip(root.length);
        final dataNode = value;
        if (pruneForest.shouldPruneUnkeptDescendants(dataPath)) {
          var newCache = pruneForest
              .child(dataPath)
              .foldKeptNodes<IncompleteData>(IncompleteData.empty(),
                  (keepPath, value, accum) {
            var op = TreeOperation.overwrite(
                Path.from([...absoluteDataPath, ...keepPath]),
                dataNode.getChild(keepPath));
            return accum.applyOperation(op);
          });
          _serverCache = _serverCache
              .removeWrite(absoluteDataPath)
              .applyOperation(newCache.toOperation());

          var p = absoluteDataPath.join('/');
          database.deleteAll(database.keysBetween(
            startKey: '$_serverCachePrefix:$p/',
            endKey: '$_serverCachePrefix:${p}0',
          ));
          _serverCache.forEachCompleteNode((k, v) {
            database.put('$_serverCachePrefix:${k.join('/')}/', v.toJson(true));
          }, absoluteDataPath);
        } else {
          // NOTE: This is technically a valid scenario (e.g. you ask to prune at / but only want to
          // prune 'foo' and 'bar' and ignore everything else).  But currently our pruning will
          // explicitly prune or keep everything we know about, so if we hit this it means our
          // tracked queries and the server cache are out of sync.
          assert(pruneForest.shouldKeep(dataPath),
              'We have data at $dataPath that is neither pruned nor kept.');
        }
      }
    });
  }

  @override
  void removeUserOperation(int writeId) {
    database.delete('$_userWritesPrefix:$writeId');
  }

  @override
  void resetPreviouslyActiveTrackedQueries(DateTime lastUse) {
    for (var query in loadTrackedQueries()) {
      if (query.active) {
        query = query.setActiveState(false).updateLastUse(lastUse);
        saveTrackedQuery(query);
      }
    }
  }

  @override
  void saveTrackedQuery(TrackedQuery trackedQuery) {
    database.put(
        '$_trackedQueryPrefix:${trackedQuery.id}', trackedQuery.toJson());
  }

  @override
  void saveUserOperation(TreeOperation operation, int writeId) {
    database.put('$_userWritesPrefix:$writeId', operation.toJson());
  }

  @override
  IncompleteData serverCache(Path<Name> path) {
    return _serverCache.child(path);
  }

  @override
  int serverCacheEstimatedSizeInBytes() {
    return _serverCache.estimatedStorageSize;
  }

  @override
  void setTransactionSuccessful() {}

  @override
  Future<void> close() async {
    _writeToDatabaseFuture = null;
    await _writeToDatabase();
  }
}

class KeyValueDatabase {
  final Box box;

  Map<String, dynamic>? _transaction;

  KeyValueDatabase(this.box);

  bool get isInsideTransaction => _transaction != null;

  Iterable<dynamic> valuesBetween(
      {required String startKey, required String endKey}) {
    // TODO merge transaction data
    return keysBetween(startKey: startKey, endKey: endKey)
        .map((k) => box.get(k));
  }

  Iterable<String> keysBetween(
      {required String startKey, required String endKey}) sync* {
    // TODO merge transaction data
    for (var k in box.keys) {
      if (Comparable.compare(k, startKey) < 0) continue;
      if (Comparable.compare(k, endKey) > 0) return;
      yield k as String;
    }
  }

  bool containsKey(String key) {
    return box.containsKey(key);
  }

  void beginTransaction() {
    assert(!isInsideTransaction,
        'runInTransaction called when an existing transaction is already in progress.');
    _transaction = {};
  }

  Future<void> endTransaction() {
    assert(isInsideTransaction);
    var v = _transaction!;
    _transaction = null;
    var f = Future.wait(
        [box.putAll(v), box.deleteAll(v.keys.where((k) => v[k] == null))]);
    return f;
  }

  void close() {
    box.close();
  }

  void delete(String key) {
    _verifyInsideTransaction();
    _transaction![key] = null;
  }

  void deleteAll(Iterable<String> keys) {
    _verifyInsideTransaction();
    for (var k in keys) {
      _transaction![k] = null;
    }
  }

  void put(String key, dynamic value) {
    _verifyInsideTransaction();
    _transaction![key] = value;
  }

  void _verifyInsideTransaction() {
    assert(
        isInsideTransaction, 'Transaction expected to already be in progress.');
  }
}

extension IncompleteDataX on IncompleteData {
  int get estimatedStorageSize {
    var bytes = 0;
    forEachCompleteNode((k, v) {
      bytes +=
          k.join('/').length + json.encode(v.toJson(true)).toString().length;
    });
    return bytes;
  }
}

extension TreeOperationX on TreeOperation {
  static TreeOperation fromJson(Map<String, dynamic> json) {
    if (json.containsKey('s')) {
      return TreeOperation.overwrite(
          Name.parsePath(json['p']), TreeStructuredData.fromJson(json['s']));
    }
    var v = json['m'] as Map;
    return TreeOperation.merge(Name.parsePath(json['p']), {
      for (var k in v.keys) Name.parsePath(k): TreeStructuredData.fromJson(v[k])
    });
  }

  Map<String, dynamic> toJson() {
    var o = nodeOperation;
    return {
      'p': path.join('/'),
      if (o is Overwrite) 's': o.value.toJson(true),
      if (o is Merge)
        'm': {
          for (var c in o.overwrites)
            c.path.join('/'): (c.nodeOperation as Overwrite).value.toJson(true)
        }
    };
  }
}
