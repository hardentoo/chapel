/*
 * Copyright 2004-2016 Cray Inc.
 * Other additional copyright holders may be indicated within.
 * 
 * The entirety of this work is licensed under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * 
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

module ChapelDistribution {

  use List;

  extern proc chpl_task_yield();

  //
  // Abstract distribution class
  //
  pragma "base dist"
  class BaseDist {
    // The common case seems to be local access to this class, so we
    // will use explicit processor atomics, even when network
    // atomics are available
    var _distCnt: atomic_refcnt; // distribution reference count
    var _doms: list(BaseDom);   // domains declared over this distribution
    var _domsLock: atomicflag;  //   and lock for concurrent access
  
    pragma "dont disable remote value forwarding"
    proc destroyDist(): int {
      compilerAssert(!noRefCount);
      return decRefCount();
    }
  
    inline proc remove_dom(x) {
      on this {
        _lock_doms();
        _doms.remove(x);
        _unlock_doms();
      }
    }
  
    inline proc add_dom(x) {
      on this {
        _lock_doms();
        _doms.append(x);
        _unlock_doms();
      }
    }
  
    inline proc _lock_doms() {
      // WARNING: If you are calling this function directly from
      // a remote locale, you should consider wrapping the call in
      // an on clause to avoid excessive remote forks due to the
      // testAndSet()
      while (_domsLock.testAndSet()) do chpl_task_yield();
    }
  
    inline proc _unlock_doms() {
      _domsLock.clear();
    }
  
    proc dsiNewRectangularDom(param rank: int, type idxType, param stridable: bool) {
      compilerError("rectangular domains not supported by this distribution");
    }
  
    proc dsiNewAssociativeDom(type idxType, param parSafe: bool) {
      compilerError("associative domains not supported by this distribution");
    }
  
    proc dsiNewAssociativeDom(type idxType, param parSafe: bool)
    where isEnumType(idxType) {
      compilerError("enumerated domains not supported by this distribution");
    }
  
    proc dsiNewOpaqueDom(type idxType, param parSafe: bool) {
      compilerError("opaque domains not supported by this distribution");
    }
  
    proc dsiNewSparseDom(param rank: int, type idxType, dom: domain) {
      compilerError("sparse domains not supported by this distribution");
    }
  
    inline proc incRefCount(cnt=1) {
      compilerAssert(!noRefCount);
      _distCnt.inc(cnt);
    }

    inline proc decRefCount() {
      compilerAssert(!noRefCount);
      const cnt = _distCnt.dec();
      if cnt < 0 then
          halt("distribution reference count is negative!");
      return cnt;
    }

    proc dsiSupportsPrivatization() param return false;
    proc dsiRequiresPrivatization() param return false;
  
    proc dsiDestroyDistClass() { }
  
    proc dsiDisplayRepresentation() { }
  }
  
  //
  // Abstract domain classes
  //
  pragma "base domain"
  class BaseDom {
    // The common case seems to be local access to this class, so we
    // will use explicit processor atomics, even when network
    // atomics are available
    var _domCnt: atomic_refcnt; // domain reference count
    var _arrs: list(BaseArr);  // arrays declared over this domain
    var _arrsLock: atomicflag; //   and lock for concurrent access
  
    proc dsiMyDist(): BaseDist {
      halt("internal error: dsiMyDist is not implemented");
      return nil;
    }
  
    pragma "dont disable remote value forwarding"
    proc destroyDom(): int {
      compilerAssert(!noRefCount);
      var cnt = decRefCount();
      if cnt == 0 && dsiLinksDistribution() {
          var dist = dsiMyDist();
          on dist {
            local dist.remove_dom(this);
            var cnt = dist.destroyDist();
            if cnt == 0 then
              delete dist;
          }
      }
      return cnt;
    }
  
    inline proc remove_arr(x) {
      on this {
        _lock_arrs();
        _arrs.remove(x);
        _unlock_arrs();
      }
    }
  
    inline proc add_arr(x) {
      on this {
        _lock_arrs();
        _arrs.append(x);
        _unlock_arrs();
      }
    }
  
    inline proc _lock_arrs() {
      // WARNING: If you are calling this function directly from
      // a remote locale, you should consider wrapping the call in
      // an on clause to avoid excessive remote forks due to the
      // testAndSet()
      while (_arrsLock.testAndSet()) do chpl_task_yield();
    }
  
    inline proc _unlock_arrs() {
      _arrsLock.clear();
    }
  
    // used for associative domains/arrays
    proc _backupArrays() {
      for arr in _arrs do
        arr._backupArray();
    }
  
    proc _removeArrayBackups() {
      for arr in _arrs do
        arr._removeArrayBackup();
    }
  
    proc _preserveArrayElements(oldslot, newslot) {
      for arr in _arrs do
        arr._preserveArrayElement(oldslot, newslot);
    }
  
    inline proc incRefCount(cnt=1) {
      compilerAssert(!noRefCount);
      _domCnt.inc(cnt);
    }

    inline proc decRefCount() {
      compilerAssert(!noRefCount);
      const cnt = _domCnt.dec(); //_domCnt.fetchSub(1)-1;
      if cnt < 0 then
          halt("domain reference count is negative!");
      return cnt;
    }

    proc dsiSupportsPrivatization() param return false;
    proc dsiRequiresPrivatization() param return false;
  
    // false for default distribution so that we don't increment the
    // default distribution's reference count and add domains to the
    // default distribution's list of domains
    proc linksDistribution() param return true;
  
    // dynamically-dispatched counterpart of linksDistribution
    proc dsiLinksDistribution() return true;
  
    proc dsiDisplayRepresentation() { }
  }
  
  class BaseRectangularDom : BaseDom {
    proc dsiClear() {
      halt("clear not implemented for this distribution");
    }
  
    proc clearForIteratableAssign() {
      compilerError("Illegal assignment to a rectangular domain");
    }
  
    proc dsiAdd(x) {
      compilerError("Cannot add indices to a rectangular domain");
    }
  
    proc dsiRemove(x) {
      compilerError("Cannot remove indices from a rectangular domain");
    }
  }
  
  class BaseSparseDom : BaseDom {
    // these should be generic fields of all sparse subdomains
    // NOTE this is only true for the first PR, rank and idxType should be
    // hoisted higher to the BaseDom
    param rank: int;
    type idxType;
    var parentDom;

    // We currently cannot have dist here. It is due to a compiler bug due to
    // inheritance of generic var fields.
    // var dist;

    var nnz = 0; //: int;
    var nnzDom = {1..nnz};

    proc dsiClear() {
      halt("clear not implemented for this distribution");
    }
  
    proc clearForIteratableAssign() {
      dsiClear();
    }

    proc dsiBulkAdd(inds: [] index(rank, idxType),
        isSorted=false, isUnique=false, preserveInds=true){

      if !isSorted && preserveInds {
        var _inds = inds;
        return bulkAdd_help(_inds, isSorted, isUnique); 
      }
      else {
        return bulkAdd_help(inds, isSorted, isUnique);
      }
    }

    inline proc _grow(size: int){
      const oldNNZDomSize = nnzDom.size;
      if (size > oldNNZDomSize) {
        const _newNNZDomSize = if (oldNNZDomSize) then 2*oldNNZDomSize else 1;
        nnzDom = {1.._newNNZDomSize};
      }
    }

    inline proc _bulkGrow(size: int) {
      if (nnz > nnzDom.size) {
        const _newNNZDomSize = (exp2(log2(nnz)+1.0)):int;

        nnzDom = {1.._newNNZDomSize};
      }
    }

    proc bulkAdd_help(inds: [?indsDom] index(rank, idxType), 
        isSorted=false, isUnique=false){
      halt("Helper function called on the BaseSparseDom");

      return -1;
    }

    // this is a helper function for bulkAdd functions in sparse subdomains.
    // NOTE:it assumes that nnz array of the sparse domain has non-negative 
    // indices. If, for some reason it changes, this function and bulkAdds have to
    // be refactored. (I think it is a safe assumption at this point and keeps the
    // function a bit cleaner than some other approach. -Engin)
    proc __getActualInsertPts(d, inds, 
        isIndsSorted, isUnique) /* where isSparseDom(d) */ {

      //find individual insert points
      //and eliminate duplicates between inds and dom
      var indivInsertPts: [inds.domain] int;
      var actualInsertPts: [inds.domain] int; //where to put in newdom

      if !isIndsSorted then sort(inds);

      //eliminate duplicates --assumes sorted
      if !isUnique {
        //make sure lastInd != inds[inds.domain.low]
        var lastInd = inds[inds.domain.low] + 1; 
        for (i, p) in zip(inds, indivInsertPts)  {
          if i == lastInd then p = -1;
          else lastInd = i;
        }
      }

      //verify sorted and no duplicates if not --fast
      if boundsChecking {
        // TODO there seems to be a bug while resolving Sort.isSorted, therefore
        // for this function the argument is still isIndsSorted, instead of
        // isSorted. This should be changed when Sort.isSorted is working.
        if !isSorted(inds) then
          halt("bulkAdd: Data not sorted, call the function with isSorted=false");

        //check duplicates assuming sorted
        const indsStart = inds.domain.low;
        const indsEnd = inds.domain.high;
        var lastInd = inds[indsStart];
        for i in indsStart+1..indsEnd {
          if inds[i] == lastInd && indivInsertPts[i] != -1 then 
            halt("There are duplicates, call the function with isUnique=false"); 
        }

        for i in inds do d.boundsCheck(i);

      }

      forall (i,p) in zip(inds, indivInsertPts) {
        if isUnique || p != -1 { //don't do anything if it's duplicate
          const (found, insertPt) = d.find(i);
          p = if found then -1 else insertPt; //mark as duplicate
        }
      }

      //shift insert points for bulk addition
      //previous indexes that are added will cause a shift in the next indexes
      var actualAddCnt = 0;

      //NOTE: this can also be done with scan
      for (ip, ap) in zip(indivInsertPts, actualInsertPts) {
        if ip != -1 {
          ap = ip + actualAddCnt;
          actualAddCnt += 1;
        }
        else ap = ip;
      }

      return (actualInsertPts, actualAddCnt);
    }

    proc boundsCheck(ind: index(rank, idxType)):void {
      if boundsChecking then
        if !(parentDom.member(ind)) then
          halt("Sparse domain/array index out of bounds: ", ind,
              " (expected to be within ", parentDom, ")");
    }

    //basic DSI functions
    proc dsiDim(d: int) { return parentDom.dim(d); }
    proc dsiDims() { return parentDom.dims(); }
    proc dsiNumIndices { return nnz; }
    proc dsiSize { return nnz; }
    proc dsiLow { return parentDom.low; }
    proc dsiHigh { return parentDom.high; }
    proc dsiStride { return parentDom.stride; }
    proc dsiAlignment { return parentDom.alignment; }
    proc dsiFirst {
      halt("dsiFirst is not implemented");
      const _tmp: rank*idxType;
      return _tmp;
    }
    proc dsiLast {
      halt("dsiLast not implemented");
      const _tmp: rank*idxType;
      return _tmp;
    }
    proc dsiAlignedLow { return parentDom.alignedLow; }
    proc dsiAlignedHigh { return parentDom.alignedHigh; }

  } // end BaseSparseDom

  // BaseSparseDom operator overloads
  proc +=(ref sd: domain, inds: [] sd.idxType) where isSparseDom(sd) && 
    sd.rank==1 {

    if inds.size == 0 then return;

    sd._value.dsiBulkAdd(inds);
  }

  proc +=(ref sd: domain, inds: [] sd.rank*sd.idxType) where isSparseDom(sd) &&
    sd.rank>1 {

    if inds.size == 0 then return;

    sd._value.dsiBulkAdd(inds);
  }

  // Currently this is not optimized for addition of a sparse
  proc +=(ref sd: domain, d: domain)
  where isSparseDom(sd) && d.rank==sd.rank && sd.idxType==d.idxType {

    if d.size == 0 then return;

    type _idxType = if sd.rank==1 then int else sd.rank*int;
    const indCount = d.numIndices;
    const arr: [{0..#indCount}] _idxType;

    //this could be a parallel loop. but ranks don't match -- doesn't compile
    for (a,i) in zip(arr,d) do a=i;

    sd._value.dsiBulkAdd(arr, true, true, false);
  }
  // end BaseSparseDom operators
  
  class BaseAssociativeDom : BaseDom {
    proc dsiClear() {
      halt("clear not implemented for this distribution");
    }
  
    proc clearForIteratableAssign() {
      dsiClear();
    }
  }
  
  class BaseOpaqueDom : BaseDom {
    proc dsiClear() {
      halt("clear not implemented for this distribution");
    }
  
    proc clearForIteratableAssign() {
      dsiClear();
    }
  }
  
  //
  // Abstract array class
  //
  pragma "base array"
  class BaseArr {
    // The common case seems to be local access to this class, so we
    // will use explicit processor atomics, even when network
    // atomics are available
    var _arrCnt: atomic_refcnt; // array reference count
    var _arrAlias: BaseArr;    // reference to base array if an alias
  
    proc dsiStaticFastFollowCheck(type leadType) param return false;
  
    proc dsiGetBaseDom(): BaseDom {
      halt("internal error: dsiGetBaseDom is not implemented");
      return nil;
    }
  
    pragma "dont disable remote value forwarding"
    proc destroyArr(): int {
      compilerAssert(!noRefCount);
      var cnt = decRefCount();
      if cnt == 0 {
        if _arrAlias {
          on _arrAlias {
            var cnt = _arrAlias.destroyArr();
            if cnt == 0 then
              delete _arrAlias;
          }
        } else {
          dsiDestroyData();
        }
      }
      if cnt == 0 {
          var dom = dsiGetBaseDom();
          on dom {
            local dom.remove_arr(this);
            var cnt = dom.destroyDom();
            if cnt == 0 then
              delete dom;
          }
      }
      return cnt;
    }
  
    proc dsiDestroyData() { }
  
    proc dsiReallocate(d: domain) {
      halt("reallocating not supported for this array type");
    }
  
    proc dsiPostReallocate() {
    }
  
    // This method is unsatisfactory -- see bradc's commit entries of
    // 01/02/08 around 14:30 for details
    proc _purge( ind: int) {
      halt("purging not supported for this array type");
    }
  
    proc _resize( length: int, old_map) {
      halt("resizing not supported for this array type");
    }
  
    //
    // Ultimately, these routines should not appear here; instead, we'd
    // like to do a dynamic cast in the sparse array class(es) that call
    // these routines in order to call them directly and avoid the
    // dynamic dispatch and leaking of this name to the class.  In order
    // to do this we'd need to hoist eltType to the base class, which
    // would require better subclassing of generic classes.  A good
    // summer project for Jonathan?
    //
    proc sparseShiftArray(shiftrange, initrange) {
      halt("sparseGrowDomain not supported for non-sparse arrays");
    }
  
    proc sparseShiftArrayBack(shiftrange) {
      halt("sparseShiftArrayBack not supported for non-sparse arrays");
    }

    proc sparseBulkShiftArray(shiftMap, oldnnz) {
      halt("sparseBulkShiftArray not supported for non-sparse arrays");
    }
  
    // methods for associative arrays
    proc clearEntry(idx, haveLock:bool = false) {
      halt("clearEntry() not supported for non-associative arrays");
    }
  
    proc _backupArray() {
      halt("_backupArray() not supported for non-associative arrays");
    }
  
    proc _removeArrayBackup() {
      halt("_removeArrayBackup() not supported for non-associative arrays");
    }
  
    proc _preserveArrayElement(oldslot, newslot) {
      halt("_preserveArrayElement() not supported for non-associative arrays");
    }
  
    inline proc incRefCount(cnt=1) {
      compilerAssert(!noRefCount);
      _arrCnt.inc(cnt);
    }

    inline proc decRefCount() {
      compilerAssert(!noRefCount);
      const cnt = _arrCnt.dec(); //_arrCnt.fetchSub(1)-1;
      if cnt < 0 then
          halt("array reference count is negative!");
      return cnt;
    }

    proc dsiSupportsAlignedFollower() param return false;
  
    proc dsiSupportsPrivatization() param return false;
    proc dsiRequiresPrivatization() param return false;
  
    proc dsiSupportsBulkTransfer() param return false;
    proc doiCanBulkTransfer() param return false;
    proc doiBulkTransfer(B){ 
      halt("This array type does not support bulk transfer.");
    }
  
    proc dsiDisplayRepresentation() { }
    proc isDefaultRectangular() param return false;
    proc dsiSupportsBulkTransferInterface() param return false;
    proc doiCanBulkTransferStride() param return false;
  }
  
}
