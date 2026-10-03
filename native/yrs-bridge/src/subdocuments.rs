//! Subdocument access: the parent map holds a subdocument as a `Doc` value, and
//! every export here either reads that value or hands it out as an owned handle.
//!
//! A handle is `Box::into_raw(Box::new(doc))`, where `Doc` is `Arc`-backed, so a
//! handle owns one reference to the shared store and `yrs_bridge_doc_destroy`
//! drops it. Release order against the parent never matters (ADR-0024).

use std::ffi::c_char;

use uuid::Uuid;
use yrs::branch::Branch;
use yrs::{Doc, Map, MapRef, ReadTxn};

use crate::{
    ffi_boundary, new_doc_with_options, read_name, write_buffer, BranchPointable, YrsBridgeBuffer,
    YrsBridgeTransaction, YRS_BRIDGE_ERR_DECODE, YRS_BRIDGE_ERR_DUPLICATE_SUBDOC_GUID,
    YRS_BRIDGE_ERR_INVALID_GUID, YRS_BRIDGE_ERR_NULL_POINTER, YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION,
    YRS_BRIDGE_ERR_TYPE_MISMATCH, YRS_BRIDGE_OK,
};

/// The subdocument stored at `key`, or the error code the caller should return:
/// the null checks, key decoding, map read, and `Out` → `Doc` cast that every
/// subdocument export needs before it can do its own one thing.
unsafe fn subdoc_at_map_key(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
) -> Result<Doc, i32> {
    if map.is_null() || transaction.is_null() {
        return Err(YRS_BRIDGE_ERR_NULL_POINTER);
    }
    let key = read_name(key)?;
    let value = MapRef::from_raw_branch(map)
        .get(&*transaction, &key)
        .ok_or(YRS_BRIDGE_ERR_TYPE_MISMATCH)?;
    value
        .cast::<Doc>()
        .map_err(|_| YRS_BRIDGE_ERR_TYPE_MISMATCH)
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_set_new_subdoc(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    guid_out: *mut YrsBridgeBuffer,
) -> i32 {
    yrs_bridge_map_set_new_subdoc_with_options(map, transaction, key, false, guid_out)
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_set_new_subdoc_with_options(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    skip_gc: bool,
    guid_out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let subdoc =
            MapRef::from_raw_branch(map).insert(transaction, key, new_doc_with_options(skip_gc));
        write_buffer(subdoc.guid().to_string().into_bytes(), guid_out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_set_new_subdoc_with_guid(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    guid: *const c_char,
    guid_out: *mut YrsBridgeBuffer,
) -> i32 {
    yrs_bridge_map_set_new_subdoc_with_guid_and_options(
        map,
        transaction,
        key,
        guid,
        false,
        guid_out,
    )
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_set_new_subdoc_with_guid_and_options(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    guid: *const c_char,
    skip_gc: bool,
    guid_out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let guid = match read_name(guid).and_then(|guid| {
            Uuid::parse_str(&guid)
                .map(|uuid| uuid.to_string())
                .map_err(|_| YRS_BRIDGE_ERR_INVALID_GUID)
        }) {
            Ok(guid) => guid,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        if transaction
            .subdoc_guids()
            .any(|existing| existing.as_ref() == guid)
        {
            return YRS_BRIDGE_ERR_DUPLICATE_SUBDOC_GUID;
        }
        let mut options = crate::yjs_compatible_options(skip_gc);
        options.guid = guid.into();
        let subdoc =
            MapRef::from_raw_branch(map).insert(transaction, key, Doc::with_options(options));
        write_buffer(subdoc.guid().to_string().into_bytes(), guid_out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_get_subdoc_guid(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| match subdoc_at_map_key(map, transaction, key) {
        Ok(subdoc) => write_buffer(subdoc.guid().to_string().into_bytes(), out),
        Err(code) => code,
    })
}

/// Returns the subdocument stored at `key` as an owned document handle, which
/// the caller releases with `yrs_bridge_doc_destroy`.
#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_get_subdoc_doc(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    doc_out: *mut *mut Doc,
) -> i32 {
    ffi_boundary(|| {
        if doc_out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        match subdoc_at_map_key(map, transaction, key) {
            Ok(subdoc) => {
                *doc_out = Box::into_raw(Box::new(subdoc));
                YRS_BRIDGE_OK
            }
            Err(code) => code,
        }
    })
}

/// Returns the subdocument registered in this document under `guid` as an owned
/// document handle. GUID uniqueness is the application's contract: with two
/// subdocuments under one GUID the match is arbitrary, because `subdocs()`
/// walks a hash map.
#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_transaction_get_subdoc_doc_by_guid(
    transaction: *mut YrsBridgeTransaction,
    guid: *const c_char,
    doc_out: *mut *mut Doc,
) -> i32 {
    ffi_boundary(|| {
        if transaction.is_null() || doc_out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let guid = match read_name(guid) {
            Ok(guid) => guid,
            Err(code) => return code,
        };
        let Some(subdoc) = (*transaction)
            .subdocs()
            .find(|subdoc| subdoc.guid().as_ref() == guid.as_str())
        else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        *doc_out = Box::into_raw(Box::new(subdoc.clone()));
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_load_subdoc(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        let subdoc = match subdoc_at_map_key(map, transaction, key) {
            Ok(subdoc) => subdoc,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        subdoc.load(transaction);
        YRS_BRIDGE_OK
    })
}

/// Destroys the subdocument stored at `key`, following yrs: destroy observers
/// fire, the instance detaches, and the parent entry stays as a fresh, unloaded
/// reference with the same GUID.
#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_clear_subdoc(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        let subdoc = match subdoc_at_map_key(map, transaction, key) {
            Ok(subdoc) => subdoc,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        subdoc.destroy(Some(transaction));
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_transaction_subdoc_guids(
    transaction: *mut YrsBridgeTransaction,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let guids: Vec<_> = (*transaction)
            .subdoc_guids()
            .map(|guid| guid.to_string())
            .collect();
        match serde_json::to_vec(&guids) {
            Ok(bytes) => write_buffer(bytes, out),
            Err(_) => YRS_BRIDGE_ERR_DECODE,
        }
    })
}
