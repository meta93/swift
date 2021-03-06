//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// A wrapper around _RawDictionaryStorage that provides most of the
/// implementation of Dictionary.
@usableFromInline
@_fixed_layout
internal struct _NativeDictionary<Key: Hashable, Value> {
  @usableFromInline
  internal typealias Element = (key: Key, value: Value)

  /// See this comments on _RawDictionaryStorage and its subclasses to
  /// understand why we store an untyped storage here.
  @usableFromInline
  internal var _storage: _RawDictionaryStorage

  /// Constructs an instance from the empty singleton.
  @inlinable
  internal init() {
    self._storage = _RawDictionaryStorage.empty
  }

  /// Constructs a dictionary adopting the given storage.
  @inlinable
  internal init(_ storage: _RawDictionaryStorage) {
    self._storage = storage
  }

  @usableFromInline
  @_effects(releasenone)
  internal init(capacity: Int) {
    let scale = _HashTable.scale(forCapacity: capacity)
    self._storage = _DictionaryStorage<Key, Value>.allocate(scale: scale)
  }

#if _runtime(_ObjC)
  @inlinable
  internal init(_ cocoa: _CocoaDictionary) {
    self.init(cocoa, capacity: cocoa.count)
  }

  @inlinable
  internal init(_ cocoa: _CocoaDictionary, capacity: Int) {
    _sanityCheck(cocoa.count <= capacity)
    self.init(capacity: capacity)
    for (key, value) in cocoa {
      insertNew(
        key: _forceBridgeFromObjectiveC(key, Key.self),
        value: _forceBridgeFromObjectiveC(value, Value.self))
    }
  }
#endif
}

extension _NativeDictionary { // Primitive fields
  @inlinable
  internal var capacity: Int {
    @inline(__always)
    get {
      return _assumeNonNegative(_storage._capacity)
    }
  }

  @inlinable
  internal var hashTable: _HashTable {
    @inline(__always) get {
      return _storage._hashTable
    }
  }

  // This API is unsafe and needs a `_fixLifetime` in the caller.
  @inlinable
  internal var _keys: UnsafeMutablePointer<Key> {
    return _storage._rawKeys.assumingMemoryBound(to: Key.self)
  }

  @inlinable
  internal var _values: UnsafeMutablePointer<Value> {
    return _storage._rawValues.assumingMemoryBound(to: Value.self)
  }
}

extension _NativeDictionary { // Low-level unchecked operations
  @inlinable
  @inline(__always)
  internal func uncheckedKey(at index: Index) -> Key {
    defer { _fixLifetime(self) }
    _sanityCheck(hashTable.isOccupied(index))
    return _keys[index.bucket]
  }

  @inlinable
  @inline(__always)
  internal func uncheckedValue(at index: Index) -> Value {
    defer { _fixLifetime(self) }
    _sanityCheck(hashTable.isOccupied(index))
    return _values[index.bucket]
  }

  @usableFromInline
  @inline(__always)
  internal func uncheckedInitialize(
    at index: Index,
    toKey key: Key,
    value: Value) {
    defer { _fixLifetime(self) }
    _sanityCheck(hashTable.isValid(index))
    (_keys + index.bucket).initialize(to: key)
    (_values + index.bucket).initialize(to: value)
  }

  @usableFromInline
  @inline(__always)
  internal func uncheckedDestroy(at index: Index) {
    defer { _fixLifetime(self) }
    _sanityCheck(hashTable.isOccupied(index))
    (_keys + index.bucket).deinitialize(count: 1)
    (_values + index.bucket).deinitialize(count: 1)
  }
}

extension _NativeDictionary { // Low-level lookup operations
  @inlinable
  @inline(__always)
  internal func hashValue(for key: Key) -> Int {
    return key._rawHashValue(seed: _storage._seed)
  }

  @inlinable
  @inline(__always)
  internal func find(_ key: Key) -> (index: Index, found: Bool) {
    return find(key, hashValue: self.hashValue(for: key))
  }

  /// Search for a given element, assuming it has the specified hash value.
  ///
  /// If the element is not present in this set, return the position where it
  /// could be inserted.
  @inlinable
  @inline(__always)
  internal func find(
    _ key: Key,
    hashValue: Int
  ) -> (index: Index, found: Bool) {
    let hashTable = self.hashTable
    var index = hashTable.idealIndex(forHashValue: hashValue)
    while hashTable._isOccupied(index) {
      if uncheckedKey(at: index) == key {
        return (index, true)
      }
      index = hashTable.index(wrappedAfter: index)
    }
    return (index, false)
  }
}

extension _NativeDictionary { // ensureUnique
  @inlinable
  internal mutating func resize(capacity: Int) {
    let capacity = Swift.max(capacity, self.capacity)
    let result = _NativeDictionary(
      _DictionaryStorage<Key, Value>.allocate(capacity: capacity))
    if count > 0 {
      for index in hashTable {
        let key = (_keys + index.bucket).move()
        let value = (_values + index.bucket).move()
        result._unsafeInsertNew(key: key, value: value)
      }
      // Clear out old storage, ensuring that its deinit won't overrelease the
      // elements we've just moved out.
      _storage._hashTable.clear()
      _storage._count = 0
    }
    _storage = result._storage
  }

  @inlinable
  internal mutating func copy(capacity: Int) -> Bool {
    let capacity = Swift.max(capacity, self.capacity)
    let (newStorage, rehash) = _DictionaryStorage<Key, Value>.reallocate(
      original: _storage,
      capacity: capacity)
    let result = _NativeDictionary(newStorage)
    if count > 0 {
      if rehash {
        for index in hashTable {
          result._unsafeInsertNew(
            key: self.uncheckedKey(at: index),
            value: self.uncheckedValue(at: index))
        }
      } else {
        result.hashTable.copyContents(of: hashTable)
        result._storage._count = self.count
        for index in hashTable {
          let key = uncheckedKey(at: index)
          let value = uncheckedValue(at: index)
          result.uncheckedInitialize(at: index, toKey: key, value: value)
        }
      }
    }
    _storage = result._storage
    return rehash
  }

  /// Ensure storage of self is uniquely held and can hold at least `capacity`
  /// elements. Returns true iff contents were rehashed.
  @inlinable
  @inline(__always)
  internal mutating func ensureUnique(isUnique: Bool, capacity: Int) -> Bool {
    if _fastPath(capacity <= self.capacity && isUnique) {
      return false
    }
    guard isUnique else {
      return copy(capacity: capacity)
    }
    resize(capacity: capacity)
    return true
  }

  @inlinable
  internal mutating func reserveCapacity(_ capacity: Int, isUnique: Bool) {
    _ = ensureUnique(isUnique: isUnique, capacity: capacity)
  }
}

extension _NativeDictionary: _DictionaryBuffer {
  @usableFromInline
  internal typealias Index = _HashTable.Index

  @inlinable
  internal var startIndex: Index {
    return hashTable.startIndex
  }

  @inlinable
  internal var endIndex: Index {
    return hashTable.endIndex
  }

  @inlinable
  internal func index(after index: Index) -> Index {
    return hashTable.index(after: index)
  }

  @inlinable
  internal func index(forKey key: Key) -> Index? {
    if count == 0 {
      // Fast path that avoids computing the hash of the key.
      return nil
    }
    let (index, found) = find(key)
    return found ? index : nil
  }

  @inlinable
  internal var count: Int {
    @inline(__always) get {
      return _assumeNonNegative(_storage._count)
    }
  }

  @inlinable
  @inline(__always)
  func contains(_ key: Key) -> Bool {
    return find(key).found
  }

  @inlinable
  @inline(__always)
  func lookup(_ key: Key) -> Value? {
    if count == 0 {
      // Fast path that avoids computing the hash of the key.
      return nil
    }
    let (index, found) = self.find(key)
    return found ? self.uncheckedValue(at: index) : nil
  }

  @inlinable
  @inline(__always)
  func lookup(_ index: Index) -> (key: Key, value: Value) {
    _precondition(hashTable.isOccupied(index),
      "Attempting to access Dictionary elements using an invalid Index")
    let key = self.uncheckedKey(at: index)
    let value = self.uncheckedValue(at: index)
    return (key, value)
  }

  @inlinable
  @inline(__always)
  func key(at index: Index) -> Key {
    _precondition(hashTable.isOccupied(index),
      "Attempting to access Dictionary elements using an invalid Index")
    return self.uncheckedKey(at: index)
  }

  @inlinable
  @inline(__always)
  func value(at index: Index) -> Value {
    _precondition(hashTable.isOccupied(index),
      "Attempting to access Dictionary elements using an invalid Index")
    return self.uncheckedValue(at: index)
  }
}

// This function has a highly visible name to make it stand out in stack traces.
@usableFromInline
@inline(never)
internal func KEY_TYPE_OF_DICTIONARY_VIOLATES_HASHABLE_REQUIREMENTS(
  _ keyType: Any.Type
) -> Never {
  _assertionFailure(
    "Fatal error",
    """
    Duplicate keys of type '\(keyType)' were found in a Dictionary.
    This usually means either that the type violates Hashable's requirements, or
    that members of such a dictionary were mutated after insertion.
    """,
    flags: _fatalErrorFlags())
}

extension _NativeDictionary { // Insertions
  /// Insert a new element into uniquely held storage.
  /// Storage must be uniquely referenced with adequate capacity.
  /// The `key` must not be already present in the Dictionary.
  @inlinable
  internal func _unsafeInsertNew(key: Key, value: Value) {
    _sanityCheck(count + 1 <= capacity)
    let hashValue = self.hashValue(for: key)
    if _isDebugAssertConfiguration() {
      // In debug builds, perform a full lookup and trap if we detect duplicate
      // elements -- these imply that the Element type violates Hashable
      // requirements. This is generally more costly than a direct insertion,
      // because we'll need to compare elements in case of hash collisions.
      let (index, found) = find(key, hashValue: hashValue)
      guard !found else {
        KEY_TYPE_OF_DICTIONARY_VIOLATES_HASHABLE_REQUIREMENTS(Key.self)
      }
      hashTable.insert(index)
      uncheckedInitialize(at: index, toKey: key, value: value)
    } else {
      let index = hashTable.insertNew(hashValue: hashValue)
      uncheckedInitialize(at: index, toKey: key, value: value)
    }
    _storage._count += 1
  }

  /// Insert a new entry into uniquely held storage.
  /// Storage must be uniquely referenced.
  /// The `key` must not be already present in the Dictionary.
  @inlinable
  internal mutating func insertNew(key: Key, value: Value) {
    _ = ensureUnique(isUnique: true, capacity: count + 1)
    _unsafeInsertNew(key: key, value: value)
  }

  /// Same as find(_:), except assume a corresponding key/value pair will be
  /// inserted if it doesn't already exist, and mutated if it does exist. When
  /// this function returns, the storage is guaranteed to be native, uniquely
  /// held, and with enough capacity for a single insertion (if the key isn't
  /// already in the dictionary.)
  @inlinable
  @inline(__always)
  internal mutating func mutatingFind(
    _ key: Key,
    isUnique: Bool
  ) -> (index: Index, found: Bool) {
    let (index, found) = find(key)

    // Prepare storage.
    // If `key` isn't in the dictionary yet, assume that this access will end
    // up inserting it. (If we guess wrong, we might needlessly expand
    // storage; that's fine.) Otherwise this can only be a removal or an
    // in-place mutation.
    let rehashed = ensureUnique(
      isUnique: isUnique,
      capacity: count + (found ? 0 : 1))
    guard rehashed else { return (index, found) }
    let (i, f) = find(key)
    if f != found {
      KEY_TYPE_OF_DICTIONARY_VIOLATES_HASHABLE_REQUIREMENTS(Key.self)
    }
    return (i, found)
  }

  @inlinable
  internal func _insert(at index: Index, key: Key, value: Value) {
    _sanityCheck(count < capacity)
    hashTable.insert(index)
    uncheckedInitialize(at: index, toKey: key, value: value)
    _storage._count += 1
  }

  @inlinable
  internal mutating func updateValue(
    _ value: Value,
    forKey key: Key,
    isUnique: Bool
  ) -> Value? {
    let (index, found) = mutatingFind(key, isUnique: isUnique)
    if found {
      let oldValue = (_values + index.bucket).move()
      (_values + index.bucket).initialize(to: value)
      // FIXME: Replacing the old key with the new is unnecessary, unintuitive,
      // and actively harmful to some usecases. We shouldn't do it.
      // rdar://problem/32144087
      (_keys + index.bucket).pointee = key
      return oldValue
    }
    _insert(at: index, key: key, value: value)
    return nil
  }

  @inlinable
  internal mutating func setValue(
    _ value: Value,
    forKey key: Key,
    isUnique: Bool
  ) {
    let (index, found) = mutatingFind(key, isUnique: isUnique)
    if found {
      (_values + index.bucket).pointee = value
      // FIXME: Replacing the old key with the new is unnecessary, unintuitive,
      // and actively harmful to some usecases. We shouldn't do it.
      // rdar://problem/32144087
      (_keys + index.bucket).pointee = key
    } else {
      _insert(at: index, key: key, value: value)
    }
  }
}

extension _NativeDictionary: _HashTableDelegate {
  @inlinable
  @inline(__always)
  internal func hashValue(at index: Index) -> Int {
    return hashValue(for: uncheckedKey(at: index))
  }

  @inlinable
  @inline(__always)
  internal func moveEntry(from source: Index, to target: Index) {
    (_keys + target.bucket)
      .moveInitialize(from: _keys + source.bucket, count: 1)
    (_values + target.bucket)
      .moveInitialize(from: _values + source.bucket, count: 1)
  }
}

extension _NativeDictionary { // Deletion
  @inlinable
  internal func _delete(at index: Index) {
    hashTable.delete(at: index, with: self)
    _storage._count -= 1
    _sanityCheck(_storage._count >= 0)
  }

  @inlinable
  @inline(__always)
  internal mutating func uncheckedRemove(
    at index: Index,
    isUnique: Bool
  ) -> Element {
    _sanityCheck(hashTable.isOccupied(index))
    let rehashed = ensureUnique(isUnique: isUnique, capacity: capacity)
    _sanityCheck(!rehashed)
    let oldKey = (_keys + index.bucket).move()
    let oldValue = (_values + index.bucket).move()
    _delete(at: index)
    return (oldKey, oldValue)
  }

  @inlinable
  @inline(__always)
  internal mutating func remove(at index: Index, isUnique: Bool) -> Element {
    _precondition(hashTable.isOccupied(index), "Invalid index")
    return uncheckedRemove(at: index, isUnique: isUnique)
  }

  @usableFromInline
  internal mutating func removeAll(isUnique: Bool) {
    guard isUnique else {
      let scale = self._storage._scale
      _storage = _DictionaryStorage<Key, Value>.allocate(scale: scale)
      return
    }
    for index in hashTable {
      (_keys + index.bucket).deinitialize(count: 1)
      (_values + index.bucket).deinitialize(count: 1)
    }
    hashTable.clear()
    _storage._count = 0
  }
}

extension _NativeDictionary { // High-level operations
  @inlinable
  internal func mapValues<T>(
    _ transform: (Value) throws -> T
  ) rethrows -> _NativeDictionary<Key, T> {
    let result = _NativeDictionary<Key, T>(capacity: capacity)
    // Because the keys in the current and new buffer are the same, we can
    // initialize to the same locations in the new buffer, skipping hash value
    // recalculations.
    for index in hashTable {
      let key = self.uncheckedKey(at: index)
      let value = self.uncheckedValue(at: index)
      try result._insert(at: index, key: key, value: transform(value))
    }
    return result
  }

  @inlinable
  internal mutating func merge<S: Sequence>(
    _ keysAndValues: S,
    isUnique: Bool,
    uniquingKeysWith combine: (Value, Value) throws -> Value
  ) rethrows where S.Element == (Key, Value) {
    var isUnique = isUnique
    for (key, value) in keysAndValues {
      let (index, found) = mutatingFind(key, isUnique: isUnique)
      isUnique = true
      if found {
        do {
          let v = (_values + index.bucket).move()
          let newValue = try combine(v, value)
          (_values + index.bucket).initialize(to: newValue)
        } catch _MergeError.keyCollision {
          fatalError("Duplicate values for key: '\(key)'")
        }
      } else {
        _insert(at: index, key: key, value: value)
      }
    }
  }

  @inlinable
  @inline(__always)
  internal init<S: Sequence>(
    grouping values: S,
    by keyForValue: (S.Element) throws -> Key
  ) rethrows where Value == [S.Element] {
    self.init()
    for value in values {
      let key = try keyForValue(value)
      let (index, found) = mutatingFind(key, isUnique: true)
      if found {
        _values[index.bucket].append(value)
      } else {
        _insert(at: index, key: key, value: [value])
      }
    }
  }
}

extension _NativeDictionary: Sequence {
  @usableFromInline
  @_fixed_layout
  internal struct Iterator {
    // The iterator is iterating over a frozen view of the collection state, so
    // it keeps its own reference to the dictionary.
    @usableFromInline
    internal let base: _NativeDictionary
    @usableFromInline
    internal var iterator: _HashTable.Iterator

    @inlinable
    init(_ base: _NativeDictionary) {
      self.base = base
      self.iterator = base.hashTable.makeIterator()
    }
  }

  @inlinable
  internal func makeIterator() -> Iterator {
    return Iterator(self)
  }
}

extension _NativeDictionary.Iterator: IteratorProtocol {
  @usableFromInline
  internal typealias Element = (key: Key, value: Value)

  @inlinable
  internal mutating func next() -> Element? {
    guard let index = iterator.next() else { return nil }
    let key = base.uncheckedKey(at: index)
    let value = base.uncheckedValue(at: index)
    return (key, value)
  }
}

