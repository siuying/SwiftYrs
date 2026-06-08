use std::collections::HashMap;
use std::ffi::{c_char, c_uchar, c_void, CStr};
use std::ops::Bound;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::null_mut;
use std::sync::Arc;

use yrs::branch::{Branch, BranchPtr};
use yrs::sync::awareness::AwarenessUpdate;
use yrs::sync::{Awareness, DefaultProtocol, Message, Protocol, SyncMessage};
use yrs::types::text::YChange;
use yrs::types::xml::{
    XmlElementPrelim, XmlElementRef, XmlFragment, XmlFragmentRef, XmlTextPrelim, XmlTextRef,
};
use yrs::types::{
    AsPrelim, Attrs, Change, Delta, EntryChange, Observable, PathSegment, ToJson, TypeRef,
};
use yrs::encoding::read::Cursor;
use yrs::updates::decoder::{Decode, Decoder, DecoderV1};
use yrs::updates::encoder::{Encode, Encoder, EncoderV1, EncoderV2};
use yrs::{
    Any, Array, ArrayPrelim, ArrayRef, Assoc, ClientID, Doc, GetString, In, IndexedSequence, Map,
    MapPrelim, MapRef, Out, Quotable, ReadTxn, StateVector, StickyIndex, Store, Text, TextPrelim,
    Subscription, TextRef, Transact, Update, UndoManager, WeakRef, Xml,
};

const YRS_BRIDGE_OK: i32 = 0;
const YRS_BRIDGE_ERR_NULL_POINTER: i32 = 1;
const YRS_BRIDGE_ERR_TRANSACTION_CONFLICT: i32 = 2;
const YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION: i32 = 3;
const YRS_BRIDGE_ERR_DECODE: i32 = 4;
const YRS_BRIDGE_ERR_NATIVE_PANIC: i32 = 5;
const YRS_BRIDGE_ERR_TYPE_MISMATCH: i32 = 6;

const YRS_BRIDGE_VALUE_UNDEFINED: i32 = 0;
const YRS_BRIDGE_VALUE_NULL: i32 = 1;
const YRS_BRIDGE_VALUE_BOOL: i32 = 2;
const YRS_BRIDGE_VALUE_INT: i32 = 3;
const YRS_BRIDGE_VALUE_DOUBLE: i32 = 4;
const YRS_BRIDGE_VALUE_STRING: i32 = 5;
const YRS_BRIDGE_VALUE_BINARY: i32 = 6;
const YRS_BRIDGE_VALUE_TEXT: i32 = 7;
const YRS_BRIDGE_VALUE_MAP: i32 = 8;
const YRS_BRIDGE_VALUE_ARRAY: i32 = 9;
const YRS_BRIDGE_VALUE_DOC: i32 = 10;
const YRS_BRIDGE_VALUE_XML_FRAGMENT: i32 = 11;
const YRS_BRIDGE_VALUE_WEAK: i32 = 12;
const YRS_BRIDGE_VALUE_XML_ELEMENT: i32 = 13;
const YRS_BRIDGE_VALUE_XML_TEXT: i32 = 14;

#[repr(C)]
pub struct YrsBridgeBuffer {
    data: *mut c_uchar,
    len: usize,
}

#[repr(C)]
pub struct YrsBridgeValue {
    tag: i32,
    bool_value: bool,
    int_value: i64,
    double_value: f64,
    bytes: *mut c_uchar,
    len: usize,
    branch: *mut Branch,
}

type YrsBridgeEventCallback = unsafe extern "C" fn(context: *mut c_void, data: *const c_uchar, len: usize);

#[repr(transparent)]
pub struct YrsBridgeObservation(Option<Subscription>);

#[repr(transparent)]
pub struct YrsBridgeUndoManager(UndoManager);

#[repr(transparent)]
pub struct YrsBridgeAwareness(Awareness);

#[repr(transparent)]
pub struct YrsBridgeTransaction(TransactionInner);

enum TransactionInner {
    ReadOnly(yrs::Transaction<'static>),
    ReadWrite(yrs::TransactionMut<'static>),
}

impl YrsBridgeTransaction {
    fn read_only(txn: yrs::Transaction) -> Self {
        YrsBridgeTransaction(TransactionInner::ReadOnly(unsafe {
            std::mem::transmute(txn)
        }))
    }

    fn read_write(txn: yrs::TransactionMut) -> Self {
        YrsBridgeTransaction(TransactionInner::ReadWrite(unsafe {
            std::mem::transmute(txn)
        }))
    }

    fn is_writable(&self) -> bool {
        matches!(self.0, TransactionInner::ReadWrite(_))
    }

    fn as_write_mut(&mut self) -> Option<&mut yrs::TransactionMut<'static>> {
        match &mut self.0 {
            TransactionInner::ReadOnly(_) => None,
            TransactionInner::ReadWrite(txn) => Some(txn),
        }
    }
}

impl ReadTxn for YrsBridgeTransaction {
    fn store(&self) -> &Store {
        match &self.0 {
            TransactionInner::ReadOnly(txn) => txn.store(),
            TransactionInner::ReadWrite(txn) => txn.store(),
        }
    }
}

fn ffi_boundary(work: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(work)).unwrap_or(YRS_BRIDGE_ERR_NATIVE_PANIC)
}

fn write_buffer(bytes: Vec<u8>, out: *mut YrsBridgeBuffer) -> i32 {
    if out.is_null() {
        return YRS_BRIDGE_ERR_NULL_POINTER;
    }

    let mut bytes = bytes.into_boxed_slice();
    let buffer = YrsBridgeBuffer {
        data: bytes.as_mut_ptr(),
        len: bytes.len(),
    };
    std::mem::forget(bytes);
    unsafe {
        *out = buffer;
    }
    YRS_BRIDGE_OK
}

fn owned_value_bytes(bytes: Vec<u8>) -> (*mut c_uchar, usize) {
    let mut bytes = bytes.into_boxed_slice();
    let value = (bytes.as_mut_ptr(), bytes.len());
    std::mem::forget(bytes);
    value
}

fn any_from_json(value: serde_json::Value) -> Any {
    match value {
        serde_json::Value::Null => Any::Null,
        serde_json::Value::Bool(value) => Any::Bool(value),
        serde_json::Value::Number(value) => value
            .as_i64()
            .map(Any::BigInt)
            .or_else(|| value.as_f64().map(Any::Number))
            .unwrap_or(Any::Undefined),
        serde_json::Value::String(value) => Any::String(Arc::from(value)),
        serde_json::Value::Array(values) => Any::Array(Arc::from(
            values.into_iter().map(any_from_json).collect::<Vec<_>>(),
        )),
        serde_json::Value::Object(values) => {
            let values = values
                .into_iter()
                .map(|(key, value)| (key, any_from_json(value)))
                .collect::<HashMap<_, _>>();
            Any::Map(Arc::new(values))
        }
    }
}

fn attrs_from_json(attrs_json: *const c_char) -> Result<Attrs, i32> {
    if attrs_json.is_null() {
        return Ok(Attrs::new());
    }

    let attrs_json = unsafe { CStr::from_ptr(attrs_json).to_string_lossy() };
    let value: serde_json::Value =
        serde_json::from_str(&attrs_json).map_err(|_| YRS_BRIDGE_ERR_DECODE)?;
    match value {
        serde_json::Value::Object(values) => Ok(values
            .into_iter()
            .map(|(key, value)| (Arc::<str>::from(key), any_from_json(value)))
            .collect()),
        _ => Err(YRS_BRIDGE_ERR_TYPE_MISMATCH),
    }
}

fn json_from_any(value: &Any) -> serde_json::Value {
    match value {
        Any::Undefined => serde_json::json!({ "tag": "undefined" }),
        Any::Null => serde_json::json!({ "tag": "null" }),
        Any::Bool(value) => serde_json::json!({ "tag": "bool", "value": value }),
        Any::Number(value) => serde_json::json!({ "tag": "double", "value": value }),
        Any::BigInt(value) => serde_json::json!({ "tag": "int", "value": value }),
        Any::String(value) => serde_json::json!({ "tag": "string", "value": value.as_ref() }),
        Any::Buffer(value) => serde_json::json!({ "tag": "binary", "value": value.as_ref() }),
        Any::Array(values) => {
            let values: Vec<_> = values.iter().map(json_from_any).collect();
            serde_json::json!({ "tag": "array", "value": values })
        }
        Any::Map(values) => {
            let values: serde_json::Map<_, _> = values
                .iter()
                .map(|(key, value)| (key.clone(), json_from_any(value)))
                .collect();
            serde_json::json!({ "tag": "map", "value": values })
        }
    }
}

/// Maps plain JSON to `Any` the way lib0's `writeAny` treats `JSON.parse` output:
/// every JSON number is a `number` (`Any::Number`), so small integers encode as
/// lib0 type 125 (varint) rather than type 122 (bigint). This keeps Swift's
/// `writeAny` bytes identical to the browser's for y-webrtc signaling.
fn plain_any_from_json(value: serde_json::Value) -> Any {
    match value {
        serde_json::Value::Null => Any::Null,
        serde_json::Value::Bool(value) => Any::Bool(value),
        serde_json::Value::Number(value) => Any::Number(value.as_f64().unwrap_or(f64::NAN)),
        serde_json::Value::String(value) => Any::String(Arc::from(value)),
        serde_json::Value::Array(values) => Any::Array(Arc::from(
            values.into_iter().map(plain_any_from_json).collect::<Vec<_>>(),
        )),
        serde_json::Value::Object(values) => {
            let values = values
                .into_iter()
                .map(|(key, value)| (key, plain_any_from_json(value)))
                .collect::<HashMap<_, _>>();
            Any::Map(Arc::new(values))
        }
    }
}

fn plain_json_from_any(value: &Any) -> serde_json::Value {
    match value {
        Any::Undefined | Any::Null => serde_json::Value::Null,
        Any::Bool(value) => serde_json::Value::Bool(*value),
        Any::Number(value) => serde_json::json!(value),
        Any::BigInt(value) => serde_json::json!(value),
        Any::String(value) => serde_json::Value::String(value.to_string()),
        Any::Buffer(value) => serde_json::json!(value.as_ref()),
        Any::Array(values) => {
            serde_json::Value::Array(values.iter().map(plain_json_from_any).collect())
        }
        Any::Map(values) => {
            let values: serde_json::Map<_, _> = values
                .iter()
                .map(|(key, value)| (key.clone(), plain_json_from_any(value)))
                .collect();
            serde_json::Value::Object(values)
        }
    }
}

fn json_from_out(value: &Out) -> serde_json::Value {
    match value {
        Out::Any(value) => json_from_any(value),
        Out::YText(_) => serde_json::json!({ "tag": "text" }),
        Out::YMap(_) => serde_json::json!({ "tag": "map-ref" }),
        Out::YArray(_) => serde_json::json!({ "tag": "array-ref" }),
        Out::YDoc(_) => serde_json::json!({ "tag": "doc" }),
        Out::YXmlElement(_) => serde_json::json!({ "tag": "xml-element" }),
        Out::YXmlFragment(_) => serde_json::json!({ "tag": "xml-fragment" }),
        Out::YXmlText(_) => serde_json::json!({ "tag": "xml-text" }),
        Out::YWeakLink(_) => serde_json::json!({ "tag": "weak" }),
        Out::UndefinedRef(_) => serde_json::json!({ "tag": "undefined" }),
    }
}

fn json_from_attrs(attrs: &Option<Box<Attrs>>) -> serde_json::Value {
    match attrs {
        Some(attrs) => {
            let attrs: serde_json::Map<_, _> = attrs
                .iter()
                .map(|(key, value)| (key.to_string(), json_from_any(value)))
                .collect();
            serde_json::Value::Object(attrs)
        }
        None => serde_json::Value::Object(serde_json::Map::new()),
    }
}

fn json_from_diff(diff: yrs::types::text::Diff<YChange>) -> serde_json::Value {
    serde_json::json!({
        "insert": json_from_out(&diff.insert),
        "attributes": json_from_attrs(&diff.attributes),
    })
}

unsafe fn emit_json(callback: YrsBridgeEventCallback, context: usize, value: serde_json::Value) {
    if let Ok(bytes) = serde_json::to_vec(&value) {
        callback(context as *mut c_void, bytes.as_ptr(), bytes.len());
    }
}

fn json_from_path(path: impl IntoIterator<Item = PathSegment>) -> serde_json::Value {
    let path: Vec<_> = path
        .into_iter()
        .map(|segment| match segment {
            PathSegment::Key(key) => serde_json::Value::String(key.to_string()),
            PathSegment::Index(index) => serde_json::json!(index),
        })
        .collect();
    serde_json::Value::Array(path)
}

fn json_from_delta(delta: &Delta) -> serde_json::Value {
    match delta {
        Delta::Inserted(value, attrs) => serde_json::json!({
            "kind": "insert",
            "insert": json_from_out(value),
            "attributes": json_from_attrs(attrs),
        }),
        Delta::Deleted(len) => serde_json::json!({
            "kind": "delete",
            "length": len,
        }),
        Delta::Retain(len, attrs) => serde_json::json!({
            "kind": "retain",
            "length": len,
            "attributes": json_from_attrs(attrs),
        }),
    }
}

fn json_from_change(change: &Change) -> serde_json::Value {
    match change {
        Change::Added(values) => {
            let values: Vec<_> = values.iter().map(json_from_out).collect();
            serde_json::json!({
                "kind": "insert",
                "values": values,
            })
        }
        Change::Removed(len) => serde_json::json!({
            "kind": "delete",
            "length": len,
        }),
        Change::Retain(len) => serde_json::json!({
            "kind": "retain",
            "length": len,
        }),
    }
}

fn json_from_entry_change(change: &EntryChange) -> serde_json::Value {
    match change {
        EntryChange::Inserted(value) => serde_json::json!({
            "kind": "insert",
            "value": json_from_out(value),
        }),
        EntryChange::Updated(old_value, new_value) => serde_json::json!({
            "kind": "update",
            "oldValue": json_from_out(old_value),
            "newValue": json_from_out(new_value),
        }),
        EntryChange::Removed(old_value) => serde_json::json!({
            "kind": "delete",
            "oldValue": json_from_out(old_value),
        }),
    }
}

fn json_from_keys(keys: &HashMap<Arc<str>, EntryChange>) -> serde_json::Value {
    let keys: serde_json::Map<_, _> = keys
        .iter()
        .map(|(key, value)| (key.to_string(), json_from_entry_change(value)))
        .collect();
    serde_json::Value::Object(keys)
}

fn observation(subscription: Subscription) -> *mut YrsBridgeObservation {
    Box::into_raw(Box::new(YrsBridgeObservation(Some(subscription))))
}

fn observation_result<E>(subscription: Result<Subscription, E>) -> *mut YrsBridgeObservation {
    match subscription {
        Ok(subscription) => observation(subscription),
        Err(_) => null_mut(),
    }
}

fn input_from_json(value: serde_json::Value) -> Result<In, i32> {
    match value {
        serde_json::Value::Object(mut object) => {
            let Some(tag) = object
                .remove("tag")
                .and_then(|tag| tag.as_str().map(str::to_owned))
            else {
                return Ok(In::Any(any_from_json(serde_json::Value::Object(object))));
            };

            let value = object.remove("value").unwrap_or(serde_json::Value::Null);
            match tag.as_str() {
                "undefined" => Ok(In::Any(Any::Undefined)),
                "null" => Ok(In::Any(Any::Null)),
                "bool" => Ok(In::Any(Any::Bool(value.as_bool().unwrap_or(false)))),
                "int" => Ok(In::Any(Any::BigInt(value.as_i64().unwrap_or_default()))),
                "double" => Ok(In::Any(Any::Number(value.as_f64().unwrap_or_default()))),
                "string" => Ok(In::Any(Any::String(Arc::from(
                    value.as_str().unwrap_or_default().to_owned(),
                )))),
                "binary" => {
                    let bytes = value
                        .as_array()
                        .ok_or(YRS_BRIDGE_ERR_TYPE_MISMATCH)?
                        .iter()
                        .map(|byte| byte.as_u64().map(|byte| byte as u8))
                        .collect::<Option<Vec<_>>>()
                        .ok_or(YRS_BRIDGE_ERR_TYPE_MISMATCH)?;
                    Ok(In::Any(Any::Buffer(Arc::from(bytes))))
                }
                _ => Err(YRS_BRIDGE_ERR_TYPE_MISMATCH),
            }
        }
        value => Ok(In::Any(any_from_json(value))),
    }
}

unsafe fn read_name(name: *const c_char) -> Result<String, i32> {
    if name.is_null() {
        Err(YRS_BRIDGE_ERR_NULL_POINTER)
    } else {
        Ok(CStr::from_ptr(name).to_string_lossy().into_owned())
    }
}

unsafe fn input_value(value: &YrsBridgeValue, transaction: &YrsBridgeTransaction) -> Result<In, i32> {
    match value.tag {
        YRS_BRIDGE_VALUE_UNDEFINED => Ok(In::Any(Any::Undefined)),
        YRS_BRIDGE_VALUE_NULL => Ok(In::Any(Any::Null)),
        YRS_BRIDGE_VALUE_BOOL => Ok(In::Any(Any::Bool(value.bool_value))),
        YRS_BRIDGE_VALUE_INT => Ok(In::Any(Any::BigInt(value.int_value))),
        YRS_BRIDGE_VALUE_DOUBLE => Ok(In::Any(Any::Number(value.double_value))),
        YRS_BRIDGE_VALUE_STRING => {
            if value.bytes.is_null() {
                return Err(YRS_BRIDGE_ERR_NULL_POINTER);
            }
            let bytes = std::slice::from_raw_parts(value.bytes, value.len);
            let string = std::str::from_utf8(bytes).map_err(|_| YRS_BRIDGE_ERR_DECODE)?;
            Ok(In::Any(Any::String(Arc::from(string))))
        }
        YRS_BRIDGE_VALUE_BINARY => {
            if value.bytes.is_null() {
                return Err(YRS_BRIDGE_ERR_NULL_POINTER);
            }
            let bytes = std::slice::from_raw_parts(value.bytes, value.len);
            Ok(In::Any(Any::Buffer(Arc::from(bytes))))
        }
        YRS_BRIDGE_VALUE_TEXT => {
            if value.branch.is_null() {
                return Err(YRS_BRIDGE_ERR_NULL_POINTER);
            }
            let text = TextRef::from_raw_branch(value.branch);
            Ok(In::Text(text.as_prelim(transaction)))
        }
        YRS_BRIDGE_VALUE_MAP => {
            if value.branch.is_null() {
                return Err(YRS_BRIDGE_ERR_NULL_POINTER);
            }
            let map = MapRef::from_raw_branch(value.branch);
            Ok(In::Map(map.as_prelim(transaction)))
        }
        YRS_BRIDGE_VALUE_ARRAY => {
            if value.branch.is_null() {
                return Err(YRS_BRIDGE_ERR_NULL_POINTER);
            }
            let array = ArrayRef::from_raw_branch(value.branch);
            Ok(In::Array(array.as_prelim(transaction)))
        }
        _ => Err(YRS_BRIDGE_ERR_TYPE_MISMATCH),
    }
}

fn output_value(value: Out) -> YrsBridgeValue {
    match value {
        Out::Any(any) => match any {
            Any::Undefined => YrsBridgeValue::undefined(),
            Any::Null => YrsBridgeValue::null(),
            Any::Bool(value) => YrsBridgeValue {
                tag: YRS_BRIDGE_VALUE_BOOL,
                bool_value: value,
                ..YrsBridgeValue::undefined()
            },
            Any::Number(value) => YrsBridgeValue {
                tag: YRS_BRIDGE_VALUE_DOUBLE,
                double_value: value,
                ..YrsBridgeValue::undefined()
            },
            Any::BigInt(value) => YrsBridgeValue {
                tag: YRS_BRIDGE_VALUE_INT,
                int_value: value,
                ..YrsBridgeValue::undefined()
            },
            Any::String(value) => {
                let (bytes, len) = owned_value_bytes(value.as_bytes().to_vec());
                YrsBridgeValue {
                    tag: YRS_BRIDGE_VALUE_STRING,
                    bytes,
                    len,
                    ..YrsBridgeValue::undefined()
                }
            }
            Any::Buffer(value) => {
                let (bytes, len) = owned_value_bytes(value.as_ref().to_vec());
                YrsBridgeValue {
                    tag: YRS_BRIDGE_VALUE_BINARY,
                    bytes,
                    len,
                    ..YrsBridgeValue::undefined()
                }
            }
            Any::Array(_) | Any::Map(_) => YrsBridgeValue::undefined(),
        },
        Out::YText(value) => YrsBridgeValue::branch(YRS_BRIDGE_VALUE_TEXT, value.into_raw_branch()),
        Out::YMap(value) => YrsBridgeValue::branch(YRS_BRIDGE_VALUE_MAP, value.into_raw_branch()),
        Out::YArray(value) => YrsBridgeValue::branch(YRS_BRIDGE_VALUE_ARRAY, value.into_raw_branch()),
        Out::YDoc(_) => YrsBridgeValue {
            tag: YRS_BRIDGE_VALUE_DOC,
            ..YrsBridgeValue::undefined()
        },
        Out::YXmlElement(value) => {
            YrsBridgeValue::branch(YRS_BRIDGE_VALUE_XML_ELEMENT, value.into_raw_branch())
        }
        Out::YXmlFragment(value) => {
            YrsBridgeValue::branch(YRS_BRIDGE_VALUE_XML_FRAGMENT, value.into_raw_branch())
        }
        Out::YXmlText(value) => YrsBridgeValue::branch(YRS_BRIDGE_VALUE_XML_TEXT, value.into_raw_branch()),
        Out::YWeakLink(value) => YrsBridgeValue::branch(YRS_BRIDGE_VALUE_WEAK, value.into_raw_branch()),
        Out::UndefinedRef(value) => {
            YrsBridgeValue::branch(YRS_BRIDGE_VALUE_UNDEFINED, value.into_raw_branch())
        }
    }
}

trait BranchPointable {
    fn into_raw_branch(self) -> *mut Branch;
    fn from_raw_branch(branch: *const Branch) -> Self;
}

impl<T> BranchPointable for T
where
    T: AsRef<Branch> + From<BranchPtr>,
{
    fn into_raw_branch(self) -> *mut Branch {
        self.as_ref() as *const Branch as *mut Branch
    }

    fn from_raw_branch(branch: *const Branch) -> Self {
        let branch = unsafe { branch.as_ref().unwrap() };
        T::from(BranchPtr::from(branch))
    }
}

impl YrsBridgeValue {
    fn undefined() -> Self {
        YrsBridgeValue {
            tag: YRS_BRIDGE_VALUE_UNDEFINED,
            bool_value: false,
            int_value: 0,
            double_value: 0.0,
            bytes: null_mut(),
            len: 0,
            branch: null_mut(),
        }
    }

    fn null() -> Self {
        YrsBridgeValue {
            tag: YRS_BRIDGE_VALUE_NULL,
            ..YrsBridgeValue::undefined()
        }
    }

    fn branch(tag: i32, branch: *mut Branch) -> Self {
        YrsBridgeValue {
            tag,
            branch,
            ..YrsBridgeValue::undefined()
        }
    }
}

unsafe fn decode_state_vector(data: *const c_uchar, len: usize) -> Result<StateVector, i32> {
    if data.is_null() {
        Ok(StateVector::default())
    } else {
        let bytes = std::slice::from_raw_parts(data, len);
        StateVector::decode_v1(bytes).map_err(|_| YRS_BRIDGE_ERR_DECODE)
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_get_text(doc: *mut Doc, name: *const c_char) -> *mut Branch {
    catch_unwind(AssertUnwindSafe(|| {
        if doc.is_null() {
            return null_mut();
        }
        let Ok(name) = read_name(name) else {
            return null_mut();
        };
        (*doc).get_or_insert_text(name).into_raw_branch()
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_get_map(doc: *mut Doc, name: *const c_char) -> *mut Branch {
    catch_unwind(AssertUnwindSafe(|| {
        if doc.is_null() {
            return null_mut();
        }
        let Ok(name) = read_name(name) else {
            return null_mut();
        };
        (*doc).get_or_insert_map(name).into_raw_branch()
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_get_array(doc: *mut Doc, name: *const c_char) -> *mut Branch {
    catch_unwind(AssertUnwindSafe(|| {
        if doc.is_null() {
            return null_mut();
        }
        let Ok(name) = read_name(name) else {
            return null_mut();
        };
        (*doc).get_or_insert_array(name).into_raw_branch()
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_get_xml_fragment(
    doc: *mut Doc,
    name: *const c_char,
) -> *mut Branch {
    catch_unwind(AssertUnwindSafe(|| {
        if doc.is_null() {
            return null_mut();
        }
        let Ok(name) = read_name(name) else {
            return null_mut();
        };
        (*doc).get_or_insert_xml_fragment(name).into_raw_branch()
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub extern "C" fn yrs_bridge_doc_new() -> *mut Doc {
    catch_unwind(AssertUnwindSafe(|| Box::into_raw(Box::new(Doc::new())))).unwrap_or(null_mut())
}

#[no_mangle]
pub extern "C" fn yrs_bridge_doc_new_with_client_id(client_id: u64) -> *mut Doc {
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(Doc::with_client_id(client_id)))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_destroy(doc: *mut Doc) {
    if !doc.is_null() {
        drop(Box::from_raw(doc));
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_read_transaction(
    doc: *mut Doc,
    out: *mut *mut YrsBridgeTransaction,
) -> i32 {
    ffi_boundary(|| {
        if doc.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }

        match (*doc).try_transact() {
            Ok(txn) => {
                *out = Box::into_raw(Box::new(YrsBridgeTransaction::read_only(txn)));
                YRS_BRIDGE_OK
            }
            Err(_) => YRS_BRIDGE_ERR_TRANSACTION_CONFLICT,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_write_transaction(
    doc: *mut Doc,
    out: *mut *mut YrsBridgeTransaction,
) -> i32 {
    ffi_boundary(|| {
        if doc.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }

        match (*doc).try_transact_mut() {
            Ok(txn) => {
                *out = Box::into_raw(Box::new(YrsBridgeTransaction::read_write(txn)));
                YRS_BRIDGE_OK
            }
            Err(_) => YRS_BRIDGE_ERR_TRANSACTION_CONFLICT,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_write_transaction_with_origin(
    doc: *mut Doc,
    origin: *const c_char,
    out: *mut *mut YrsBridgeTransaction,
) -> i32 {
    ffi_boundary(|| {
        if doc.is_null() || origin.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let origin = match read_name(origin) {
            Ok(origin) => origin,
            Err(code) => return code,
        };
        match (*doc).try_transact_mut_with(origin) {
            Ok(txn) => {
                *out = Box::into_raw(Box::new(YrsBridgeTransaction::read_write(txn)));
                YRS_BRIDGE_OK
            }
            Err(_) => YRS_BRIDGE_ERR_TRANSACTION_CONFLICT,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_transaction_destroy(transaction: *mut YrsBridgeTransaction) {
    if !transaction.is_null() {
        drop(Box::from_raw(transaction));
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_transaction_is_writable(
    transaction: *mut YrsBridgeTransaction,
    out: *mut bool,
) -> i32 {
    ffi_boundary(|| {
        if transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }

        *out = (*transaction).is_writable();
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_transaction_state_vector_v1(
    transaction: *mut YrsBridgeTransaction,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }

        write_buffer((*transaction).state_vector().encode_v1(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_transaction_state_diff_v1(
    transaction: *mut YrsBridgeTransaction,
    state_vector: *const c_uchar,
    state_vector_len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }

        let state_vector = match decode_state_vector(state_vector, state_vector_len) {
            Ok(state_vector) => state_vector,
            Err(code) => return code,
        };
        write_buffer((*transaction).encode_state_as_update_v1(&state_vector), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_transaction_state_diff_v2(
    transaction: *mut YrsBridgeTransaction,
    state_vector: *const c_uchar,
    state_vector_len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }

        let state_vector = match decode_state_vector(state_vector, state_vector_len) {
            Ok(state_vector) => state_vector,
            Err(code) => return code,
        };
        let mut encoder = EncoderV2::new();
        (*transaction).encode_diff(&state_vector, &mut encoder);
        write_buffer(encoder.to_vec(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_transaction_apply_v1(
    transaction: *mut YrsBridgeTransaction,
    update: *const c_uchar,
    update_len: usize,
) -> i32 {
    ffi_boundary(|| {
        if transaction.is_null() || update.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }

        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let bytes = std::slice::from_raw_parts(update, update_len);
        let Ok(update) = Update::decode_v1(bytes) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        transaction
            .apply_update(update)
            .map(|_| YRS_BRIDGE_OK)
            .unwrap_or(YRS_BRIDGE_ERR_DECODE)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_transaction_apply_v2(
    transaction: *mut YrsBridgeTransaction,
    update: *const c_uchar,
    update_len: usize,
) -> i32 {
    ffi_boundary(|| {
        if transaction.is_null() || update.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }

        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let bytes = std::slice::from_raw_parts(update, update_len);
        let Ok(update) = Update::decode_v2(bytes) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        transaction
            .apply_update(update)
            .map(|_| YRS_BRIDGE_OK)
            .unwrap_or(YRS_BRIDGE_ERR_DECODE)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_buffer_destroy(buffer: YrsBridgeBuffer) {
    if !buffer.data.is_null() {
        drop(Vec::from_raw_parts(buffer.data, buffer.len, buffer.len));
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_value_destroy(value: YrsBridgeValue) {
    if !value.bytes.is_null() {
        drop(Vec::from_raw_parts(value.bytes, value.len, value.len));
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_insert(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    value: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() || value.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let value = CStr::from_ptr(value).to_string_lossy();
        TextRef::from_raw_branch(text).insert(transaction, index, value.as_ref());
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_insert_with_attributes_json(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    value: *const c_char,
    attributes_json: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() || value.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let attrs = match attrs_from_json(attributes_json) {
            Ok(attrs) => attrs,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let value = CStr::from_ptr(value).to_string_lossy();
        TextRef::from_raw_branch(text).insert_with_attributes(
            transaction,
            index,
            value.as_ref(),
            attrs,
        );
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_format_json(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    len: u32,
    attributes_json: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() || attributes_json.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let attrs = match attrs_from_json(attributes_json) {
            Ok(attrs) => attrs,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        TextRef::from_raw_branch(text).format(transaction, index, len, attrs);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_insert_embed(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    value: YrsBridgeValue,
    attributes_json: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let input = match input_value(&value, &*transaction) {
            Ok(input) => input,
            Err(code) => return code,
        };
        let attrs = match attrs_from_json(attributes_json) {
            Ok(attrs) => attrs,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let text = TextRef::from_raw_branch(text);
        let attrs = if attrs.is_empty() {
            None
        } else {
            Some(Box::new(attrs))
        };
        let mut delta = Vec::with_capacity(2);
        if index > 0 {
            delta.push(Delta::Retain(index, None));
        }
        delta.push(Delta::Inserted(input, attrs));
        text.apply_delta(transaction, delta);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_apply_delta_json(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    delta_json: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() || delta_json.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let delta_json = CStr::from_ptr(delta_json).to_string_lossy();
        let ops: serde_json::Value = match serde_json::from_str(&delta_json) {
            Ok(value) => value,
            Err(_) => return YRS_BRIDGE_ERR_DECODE,
        };
        let Some(ops) = ops.as_array() else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };

        let mut delta = Vec::with_capacity(ops.len());
        for op in ops {
            let Some(op) = op.as_object() else {
                return YRS_BRIDGE_ERR_TYPE_MISMATCH;
            };
            if let Some(len) = op.get("retain").and_then(|value| value.as_u64()) {
                let attrs = match op.get("attributes") {
                    Some(serde_json::Value::Object(values)) if !values.is_empty() => {
                        Some(Box::new(
                            values
                                .iter()
                                .map(|(key, value)| {
                                    (Arc::<str>::from(key.as_str()), any_from_json(value.clone()))
                                })
                                .collect(),
                        ))
                    }
                    _ => None,
                };
                delta.push(Delta::Retain(len as u32, attrs));
            } else if let Some(len) = op.get("delete").and_then(|value| value.as_u64()) {
                delta.push(Delta::Deleted(len as u32));
            } else if let Some(insert) = op.get("insert") {
                let input = match input_from_json(insert.clone()) {
                    Ok(input) => input,
                    Err(code) => return code,
                };
                let attrs = match op.get("attributes") {
                    Some(serde_json::Value::Object(values)) if !values.is_empty() => {
                        Some(Box::new(
                            values
                                .iter()
                                .map(|(key, value)| {
                                    (Arc::<str>::from(key.as_str()), any_from_json(value.clone()))
                                })
                                .collect(),
                        ))
                    }
                    _ => None,
                };
                delta.push(Delta::Inserted(input, attrs));
            } else {
                return YRS_BRIDGE_ERR_TYPE_MISMATCH;
            }
        }

        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        TextRef::from_raw_branch(text).apply_delta(transaction, delta);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_remove(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    len: u32,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        TextRef::from_raw_branch(text).remove_range(transaction, index, len);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_len(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut u32,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        *out = TextRef::from_raw_branch(text).len(&*transaction);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_string(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let value = TextRef::from_raw_branch(text).get_string(&*transaction);
        write_buffer(value.into_bytes(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_chunks_json(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let chunks: Vec<_> = TextRef::from_raw_branch(text)
            .diff(&*transaction, YChange::identity)
            .into_iter()
            .map(json_from_diff)
            .collect();
        match serde_json::to_vec(&chunks) {
            Ok(bytes) => write_buffer(bytes, out),
            Err(_) => YRS_BRIDGE_ERR_DECODE,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_set(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    value: YrsBridgeValue,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() || key.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let input = match input_value(&value, &*transaction) {
            Ok(input) => input,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        MapRef::from_raw_branch(map).insert(transaction, key, input);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_set_map(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() || key.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let branch = MapRef::from_raw_branch(map)
            .insert(transaction, key, MapPrelim::default())
            .into_raw_branch();
        *out = branch;
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_set_array(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() || key.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let branch = MapRef::from_raw_branch(map)
            .insert(transaction, key, ArrayPrelim::default())
            .into_raw_branch();
        *out = branch;
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_set_text(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() || key.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let branch = MapRef::from_raw_branch(map)
            .insert(transaction, key, TextPrelim::new(""))
            .into_raw_branch();
        *out = branch;
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_get(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    out: *mut YrsBridgeValue,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() || key.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let value = MapRef::from_raw_branch(map)
            .get(&*transaction, &key)
            .map(output_value)
            .unwrap_or_else(YrsBridgeValue::undefined);
        *out = value;
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_remove(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() || key.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        MapRef::from_raw_branch(map).remove(transaction, &key);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_entries_json(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        match serde_json::to_vec(&MapRef::from_raw_branch(map).to_json(&*transaction)) {
            Ok(bytes) => write_buffer(bytes, out),
            Err(_) => YRS_BRIDGE_ERR_DECODE,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_array_insert(
    array: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    value: YrsBridgeValue,
) -> i32 {
    ffi_boundary(|| {
        if array.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let input = match input_value(&value, &*transaction) {
            Ok(input) => input,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        ArrayRef::from_raw_branch(array).insert(transaction, index, input);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_array_insert_map(
    array: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if array.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let branch = ArrayRef::from_raw_branch(array)
            .insert(transaction, index, MapPrelim::default())
            .into_raw_branch();
        *out = branch;
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_array_insert_array(
    array: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if array.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let branch = ArrayRef::from_raw_branch(array)
            .insert(transaction, index, ArrayPrelim::default())
            .into_raw_branch();
        *out = branch;
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_array_insert_text(
    array: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if array.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let branch = ArrayRef::from_raw_branch(array)
            .insert(transaction, index, TextPrelim::new(""))
            .into_raw_branch();
        *out = branch;
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_array_get(
    array: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    out: *mut YrsBridgeValue,
) -> i32 {
    ffi_boundary(|| {
        if array.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let value = ArrayRef::from_raw_branch(array)
            .get(&*transaction, index)
            .map(output_value)
            .unwrap_or_else(YrsBridgeValue::undefined);
        *out = value;
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_array_remove(
    array: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    len: u32,
) -> i32 {
    ffi_boundary(|| {
        if array.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        ArrayRef::from_raw_branch(array).remove_range(transaction, index, len);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_array_len(
    array: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut u32,
) -> i32 {
    ffi_boundary(|| {
        if array.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        *out = ArrayRef::from_raw_branch(array).len(&*transaction);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_array_values_json(
    array: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if array.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        match serde_json::to_vec(&ArrayRef::from_raw_branch(array).to_json(&*transaction)) {
            Ok(bytes) => write_buffer(bytes, out),
            Err(_) => YRS_BRIDGE_ERR_DECODE,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_len(
    xml: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut u32,
) -> i32 {
    ffi_boundary(|| {
        if xml.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        *out = match (*xml).type_ref() {
            TypeRef::XmlElement(_) => XmlElementRef::from_raw_branch(xml).len(&*transaction),
            TypeRef::XmlFragment => XmlFragmentRef::from_raw_branch(xml).len(&*transaction),
            _ => return YRS_BRIDGE_ERR_TYPE_MISMATCH,
        };
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_string(
    xml: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if xml.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let value = match (*xml).type_ref() {
            TypeRef::XmlElement(_) => XmlElementRef::from_raw_branch(xml).get_string(&*transaction),
            TypeRef::XmlFragment => XmlFragmentRef::from_raw_branch(xml).get_string(&*transaction),
            TypeRef::XmlText => XmlTextRef::from_raw_branch(xml).get_string(&*transaction),
            _ => return YRS_BRIDGE_ERR_TYPE_MISMATCH,
        };
        write_buffer(value.into_bytes(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_insert_element(
    xml: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    name: *const c_char,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if xml.is_null() || transaction.is_null() || name.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let name = match read_name(name) {
            Ok(name) => name,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let branch = match (*xml).type_ref() {
            TypeRef::XmlElement(_) => XmlElementRef::from_raw_branch(xml)
                .insert(transaction, index, XmlElementPrelim::empty(name))
                .into_raw_branch(),
            TypeRef::XmlFragment => XmlFragmentRef::from_raw_branch(xml)
                .insert(transaction, index, XmlElementPrelim::empty(name))
                .into_raw_branch(),
            _ => return YRS_BRIDGE_ERR_TYPE_MISMATCH,
        };
        *out = branch;
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_insert_text(
    xml: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if xml.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let branch = match (*xml).type_ref() {
            TypeRef::XmlElement(_) => XmlElementRef::from_raw_branch(xml)
                .insert(transaction, index, XmlTextPrelim::new(""))
                .into_raw_branch(),
            TypeRef::XmlFragment => XmlFragmentRef::from_raw_branch(xml)
                .insert(transaction, index, XmlTextPrelim::new(""))
                .into_raw_branch(),
            _ => return YRS_BRIDGE_ERR_TYPE_MISMATCH,
        };
        *out = branch;
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_get(
    xml: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    out: *mut YrsBridgeValue,
) -> i32 {
    ffi_boundary(|| {
        if xml.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let value = match (*xml).type_ref() {
            TypeRef::XmlElement(_) => XmlElementRef::from_raw_branch(xml).get(&*transaction, index),
            TypeRef::XmlFragment => XmlFragmentRef::from_raw_branch(xml).get(&*transaction, index),
            _ => return YRS_BRIDGE_ERR_TYPE_MISMATCH,
        };
        *out = value
            .map(Out::from)
            .map(output_value)
            .unwrap_or_else(YrsBridgeValue::undefined);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_remove(
    xml: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    len: u32,
) -> i32 {
    ffi_boundary(|| {
        if xml.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        match (*xml).type_ref() {
            TypeRef::XmlElement(_) => {
                XmlElementRef::from_raw_branch(xml).remove_range(transaction, index, len)
            }
            TypeRef::XmlFragment => {
                XmlFragmentRef::from_raw_branch(xml).remove_range(transaction, index, len)
            }
            _ => return YRS_BRIDGE_ERR_TYPE_MISMATCH,
        }
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_element_tag(xml: *mut Branch, out: *mut YrsBridgeBuffer) -> i32 {
    ffi_boundary(|| {
        if xml.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let TypeRef::XmlElement(_) = (*xml).type_ref() else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        let value = XmlElementRef::from_raw_branch(xml).tag().to_string();
        write_buffer(value.into_bytes(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_set_attribute(
    xml: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    value: YrsBridgeValue,
) -> i32 {
    ffi_boundary(|| {
        if xml.is_null() || transaction.is_null() || key.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let input = match input_value(&value, &*transaction) {
            Ok(input) => input,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        match (*xml).type_ref() {
            TypeRef::XmlElement(_) => {
                XmlElementRef::from_raw_branch(xml).insert_attribute(transaction, key, input);
            }
            TypeRef::XmlText => {
                XmlTextRef::from_raw_branch(xml).insert_attribute(transaction, key, input);
            }
            _ => return YRS_BRIDGE_ERR_TYPE_MISMATCH,
        }
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_get_attribute(
    xml: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    out: *mut YrsBridgeValue,
) -> i32 {
    ffi_boundary(|| {
        if xml.is_null() || transaction.is_null() || key.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let value = match (*xml).type_ref() {
            TypeRef::XmlElement(_) => {
                XmlElementRef::from_raw_branch(xml).get_attribute(&*transaction, &key)
            }
            TypeRef::XmlText => XmlTextRef::from_raw_branch(xml).get_attribute(&*transaction, &key),
            _ => return YRS_BRIDGE_ERR_TYPE_MISMATCH,
        };
        *out = value.map(output_value).unwrap_or_else(YrsBridgeValue::undefined);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_remove_attribute(
    xml: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if xml.is_null() || transaction.is_null() || key.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        match (*xml).type_ref() {
            TypeRef::XmlElement(_) => {
                XmlElementRef::from_raw_branch(xml).remove_attribute(transaction, &key)
            }
            TypeRef::XmlText => {
                XmlTextRef::from_raw_branch(xml).remove_attribute(transaction, &key)
            }
            _ => return YRS_BRIDGE_ERR_TYPE_MISMATCH,
        }
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_text_insert(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    value: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() || value.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let value = CStr::from_ptr(value).to_string_lossy();
        XmlTextRef::from_raw_branch(text).insert(transaction, index, value.as_ref());
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_text_remove(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    len: u32,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        XmlTextRef::from_raw_branch(text).remove_range(transaction, index, len);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_text_len(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut u32,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        *out = XmlTextRef::from_raw_branch(text).len(&*transaction);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_text_string(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let value = XmlTextRef::from_raw_branch(text).get_string(&*transaction);
        write_buffer(value.into_bytes(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_set_new_subdoc(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    guid_out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() || key.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let subdoc = MapRef::from_raw_branch(map).insert(transaction, key, Doc::new());
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
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() || key.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(value) = MapRef::from_raw_branch(map).get(&*transaction, &key) else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        let Ok(subdoc) = value.cast::<Doc>() else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        write_buffer(subdoc.guid().to_string().into_bytes(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_load_subdoc(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() || key.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(value) = MapRef::from_raw_branch(map).get(&*transaction, &key) else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        let Ok(subdoc) = value.cast::<Doc>() else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        subdoc.load(transaction);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_clear_subdoc(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() || key.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(value) = MapRef::from_raw_branch(map).get(&*transaction, &key) else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        let Ok(subdoc) = value.cast::<Doc>() else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
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

fn quote_bounds(
    start: u32,
    end: u32,
    start_inclusive: bool,
    end_inclusive: bool,
) -> (Bound<u32>, Bound<u32>) {
    let start = if start_inclusive {
        Bound::Included(start)
    } else {
        Bound::Excluded(start)
    };
    let end = if end_inclusive {
        Bound::Included(end)
    } else {
        Bound::Excluded(end)
    };
    (start, end)
}

fn assoc_from_i32(assoc: i32) -> Assoc {
    if assoc < 0 {
        Assoc::Before
    } else {
        Assoc::After
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_set_weak_link(
    source_map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    source_key: *const c_char,
    target_map: *mut Branch,
    target_key: *const c_char,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if source_map.is_null()
            || transaction.is_null()
            || source_key.is_null()
            || target_map.is_null()
            || target_key.is_null()
            || out.is_null()
        {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let source_key = match read_name(source_key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let target_key = match read_name(target_key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(link) = MapRef::from_raw_branch(source_map).link(&*transaction, &source_key)
        else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let weak = MapRef::from_raw_branch(target_map).insert(transaction, target_key, link);
        unsafe {
            *out = weak.into_raw_branch();
        }
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_get_weak_link(
    map: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    key: *const c_char,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if map.is_null() || transaction.is_null() || key.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let key = match read_name(key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(value) = MapRef::from_raw_branch(map).get(&*transaction, &key) else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        let Ok(weak) = WeakRef::<BranchPtr>::try_from(value) else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        unsafe {
            *out = weak.into_raw_branch();
        }
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_set_quote(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    start: u32,
    end: u32,
    start_inclusive: bool,
    end_inclusive: bool,
    target_map: *mut Branch,
    target_key: *const c_char,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null()
            || transaction.is_null()
            || target_map.is_null()
            || target_key.is_null()
            || out.is_null()
        {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let target_key = match read_name(target_key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let quote = match TextRef::from_raw_branch(text).quote(
            &*transaction,
            quote_bounds(start, end, start_inclusive, end_inclusive),
        ) {
            Ok(quote) => quote,
            Err(_) => return YRS_BRIDGE_ERR_TYPE_MISMATCH,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let weak = MapRef::from_raw_branch(target_map).insert(transaction, target_key, quote);
        unsafe {
            *out = weak.into_raw_branch();
        }
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_array_set_quote(
    array: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    start: u32,
    end: u32,
    start_inclusive: bool,
    end_inclusive: bool,
    target_map: *mut Branch,
    target_key: *const c_char,
    out: *mut *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if array.is_null()
            || transaction.is_null()
            || target_map.is_null()
            || target_key.is_null()
            || out.is_null()
        {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let target_key = match read_name(target_key) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let quote = match ArrayRef::from_raw_branch(array).quote(
            &*transaction,
            quote_bounds(start, end, start_inclusive, end_inclusive),
        ) {
            Ok(quote) => quote,
            Err(_) => return YRS_BRIDGE_ERR_TYPE_MISMATCH,
        };
        let Some(transaction) = (*transaction).as_write_mut() else {
            return YRS_BRIDGE_ERR_READ_ONLY_TRANSACTION;
        };
        let weak = MapRef::from_raw_branch(target_map).insert(transaction, target_key, quote);
        unsafe {
            *out = weak.into_raw_branch();
        }
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_weak_deref(
    weak: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut YrsBridgeValue,
) -> i32 {
    ffi_boundary(|| {
        if weak.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let weak = WeakRef::<MapRef>::from_raw_branch(weak);
        let value = weak
            .try_deref_value(&*transaction)
            .map(output_value)
            .unwrap_or_else(YrsBridgeValue::undefined);
        unsafe {
            *out = value;
        }
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_weak_values_json(
    weak: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if weak.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let weak = WeakRef::<ArrayRef>::from_raw_branch(weak);
        let values: Vec<_> = weak.unquote(&*transaction).map(|value| json_from_out(&value)).collect();
        match serde_json::to_vec(&values) {
            Ok(bytes) => write_buffer(bytes, out),
            Err(_) => YRS_BRIDGE_ERR_DECODE,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_weak_string(
    weak: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if weak.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let weak = WeakRef::<TextRef>::from_raw_branch(weak);
        write_buffer(weak.get_string(&*transaction).into_bytes(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_relative_position_json(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    assoc: i32,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(position) =
            TextRef::from_raw_branch(text).sticky_index(&*transaction, index, assoc_from_i32(assoc))
        else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        match serde_json::to_vec(&position) {
            Ok(bytes) => write_buffer(bytes, out),
            Err(_) => YRS_BRIDGE_ERR_DECODE,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_relative_position_v1(
    text: *mut Branch,
    transaction: *mut YrsBridgeTransaction,
    index: u32,
    assoc: i32,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if text.is_null() || transaction.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(position) =
            TextRef::from_raw_branch(text).sticky_index(&*transaction, index, assoc_from_i32(assoc))
        else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        write_buffer(position.encode_v1(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_relative_position_json_from_v1(
    data: *const c_uchar,
    len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if data.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        let Ok(position) = StickyIndex::decode_v1(bytes) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        match serde_json::to_vec(&position) {
            Ok(bytes) => write_buffer(bytes, out),
            Err(_) => YRS_BRIDGE_ERR_DECODE,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_relative_position_v1_from_json(
    data: *const c_uchar,
    len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if data.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        let Ok(position) = serde_json::from_slice::<StickyIndex>(bytes) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        let mut encoder = EncoderV1::new();
        position.encode(&mut encoder);
        write_buffer(encoder.to_vec(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_relative_position_offset(
    json: *const c_uchar,
    len: usize,
    transaction: *mut YrsBridgeTransaction,
    out: *mut u32,
) -> i32 {
    ffi_boundary(|| {
        if json.is_null() || transaction.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = unsafe { std::slice::from_raw_parts(json, len) };
        let Ok(position) = serde_json::from_slice::<StickyIndex>(bytes) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        let Some(offset) = position.get_offset(&*transaction) else {
            return YRS_BRIDGE_ERR_TYPE_MISMATCH;
        };
        unsafe {
            *out = offset.index;
        }
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_observation_destroy(observation: *mut YrsBridgeObservation) {
    if !observation.is_null() {
        drop(Box::from_raw(observation));
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_observe_update_v1(
    doc: *mut Doc,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if doc.is_null() {
            return null_mut();
        }
        let context = context as usize;
        observation_result((*doc).observe_update_v1(move |_transaction, event| {
            let update: Vec<_> = event.update.iter().map(|byte| serde_json::json!(byte)).collect();
            emit_json(
                callback,
                context,
                serde_json::json!({
                    "kind": "updateV1",
                    "updateV1": update,
                }),
            );
        }))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_observe_subdocs(
    doc: *mut Doc,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if doc.is_null() {
            return null_mut();
        }
        let context = context as usize;
        observation_result((*doc).observe_subdocs(move |_transaction, event| {
            let added: Vec<_> = event.added().map(|doc| doc.guid().to_string()).collect();
            let removed: Vec<_> = event.removed().map(|doc| doc.guid().to_string()).collect();
            let loaded: Vec<_> = event.loaded().map(|doc| doc.guid().to_string()).collect();
            emit_json(
                callback,
                context,
                serde_json::json!({
                    "kind": "subdocs",
                    "added": added,
                    "removed": removed,
                    "loaded": loaded,
                }),
            );
        }))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_observe_transaction_cleanup(
    doc: *mut Doc,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if doc.is_null() {
            return null_mut();
        }
        let context = context as usize;
        observation_result((*doc).observe_transaction_cleanup(move |_transaction, event| {
            emit_json(
                callback,
                context,
                serde_json::json!({
                    "kind": "transactionCleanup",
                    "beforeStateClients": event.before_state.len(),
                    "afterStateClients": event.after_state.len(),
                    "deleteSetClients": event.delete_set.len(),
                }),
            );
        }))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_doc_observe_destroy(
    doc: *mut Doc,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if doc.is_null() {
            return null_mut();
        }
        let context = context as usize;
        observation_result((*doc).observe_destroy(move |_transaction, doc| {
            emit_json(
                callback,
                context,
                serde_json::json!({
                    "kind": "destroy",
                    "guid": doc.guid().to_string(),
                }),
            );
        }))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_text_observe(
    text: *mut Branch,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if text.is_null() {
            return null_mut();
        }
        let context = context as usize;
        let text = TextRef::from_raw_branch(text);
        observation(text.observe(move |transaction, event| {
            let delta: Vec<_> = event.delta(transaction).iter().map(json_from_delta).collect();
            emit_json(
                callback,
                context,
                serde_json::json!({
                    "kind": "text",
                    "path": json_from_path(event.path()),
                    "delta": delta,
                }),
            );
        }))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_array_observe(
    array: *mut Branch,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if array.is_null() {
            return null_mut();
        }
        let context = context as usize;
        let array = ArrayRef::from_raw_branch(array);
        observation(array.observe(move |transaction, event| {
            let delta: Vec<_> = event.delta(transaction).iter().map(json_from_change).collect();
            emit_json(
                callback,
                context,
                serde_json::json!({
                    "kind": "array",
                    "path": json_from_path(event.path()),
                    "delta": delta,
                }),
            );
        }))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_map_observe(
    map: *mut Branch,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if map.is_null() {
            return null_mut();
        }
        let context = context as usize;
        let map = MapRef::from_raw_branch(map);
        observation(map.observe(move |transaction, event| {
            emit_json(
                callback,
                context,
                serde_json::json!({
                    "kind": "map",
                    "path": json_from_path(event.path()),
                    "keys": json_from_keys(event.keys(transaction)),
                }),
            );
        }))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_observe(
    xml: *mut Branch,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if xml.is_null() {
            return null_mut();
        }
        let context = context as usize;
        let type_ref = (*xml).type_ref();
        match type_ref {
            TypeRef::XmlElement(_) => {
                let xml = XmlElementRef::from_raw_branch(xml);
                observation(xml.observe(move |transaction, event| {
                    let delta: Vec<_> =
                        event.delta(transaction).iter().map(json_from_change).collect();
                    emit_json(
                        callback,
                        context,
                        serde_json::json!({
                            "kind": "xml",
                            "path": json_from_path(event.path()),
                            "childrenChanged": event.children_changed(),
                            "delta": delta,
                            "keys": json_from_keys(event.keys(transaction)),
                        }),
                    );
                }))
            }
            TypeRef::XmlFragment => {
                let xml = XmlFragmentRef::from_raw_branch(xml);
                observation(xml.observe(move |transaction, event| {
                    let delta: Vec<_> =
                        event.delta(transaction).iter().map(json_from_change).collect();
                    emit_json(
                        callback,
                        context,
                        serde_json::json!({
                            "kind": "xml",
                            "path": json_from_path(event.path()),
                            "childrenChanged": event.children_changed(),
                            "delta": delta,
                            "keys": json_from_keys(event.keys(transaction)),
                        }),
                    );
                }))
            }
            _ => null_mut(),
        }
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_xml_text_observe(
    text: *mut Branch,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if text.is_null() {
            return null_mut();
        }
        let context = context as usize;
        let text = XmlTextRef::from_raw_branch(text);
        observation(text.observe(move |transaction, event| {
            let delta: Vec<_> = event.delta(transaction).iter().map(json_from_delta).collect();
            emit_json(
                callback,
                context,
                serde_json::json!({
                    "kind": "xmlText",
                    "path": json_from_path(event.path()),
                    "delta": delta,
                    "keys": json_from_keys(event.keys(transaction)),
                }),
            );
        }))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_weak_observe(
    weak: *mut Branch,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if weak.is_null() {
            return null_mut();
        }
        let context = context as usize;
        let weak = WeakRef::<BranchPtr>::from_raw_branch(weak);
        observation(weak.observe(move |_transaction, event| {
            emit_json(
                callback,
                context,
                serde_json::json!({
                    "kind": "weak",
                    "path": json_from_path(event.path()),
                }),
            );
        }))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub extern "C" fn yrs_bridge_undo_manager_new() -> *mut YrsBridgeUndoManager {
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(YrsBridgeUndoManager(UndoManager::new())))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_destroy(undo_manager: *mut YrsBridgeUndoManager) {
    if !undo_manager.is_null() {
        drop(Box::from_raw(undo_manager));
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_add_scope(
    undo_manager: *mut YrsBridgeUndoManager,
    doc: *mut Doc,
    branch: *mut Branch,
) -> i32 {
    ffi_boundary(|| {
        if undo_manager.is_null() || doc.is_null() || branch.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        (*undo_manager)
            .0
            .expand_scope(&*doc, &BranchPtr::from(&*branch));
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_include_origin(
    undo_manager: *mut YrsBridgeUndoManager,
    origin: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if undo_manager.is_null() || origin.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let origin = match read_name(origin) {
            Ok(origin) => origin,
            Err(code) => return code,
        };
        (*undo_manager).0.include_origin(origin);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_exclude_origin(
    undo_manager: *mut YrsBridgeUndoManager,
    origin: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if undo_manager.is_null() || origin.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let origin = match read_name(origin) {
            Ok(origin) => origin,
            Err(code) => return code,
        };
        (*undo_manager).0.exclude_origin(origin);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_undo(
    undo_manager: *mut YrsBridgeUndoManager,
    out: *mut bool,
) -> i32 {
    ffi_boundary(|| {
        if undo_manager.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        *out = (*undo_manager).0.undo_blocking();
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_redo(
    undo_manager: *mut YrsBridgeUndoManager,
    out: *mut bool,
) -> i32 {
    ffi_boundary(|| {
        if undo_manager.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        *out = (*undo_manager).0.redo_blocking();
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_stop(undo_manager: *mut YrsBridgeUndoManager) {
    if !undo_manager.is_null() {
        (*undo_manager).0.reset();
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_clear(undo_manager: *mut YrsBridgeUndoManager) {
    if !undo_manager.is_null() {
        (*undo_manager).0.clear_all();
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_undo_stack_len(
    undo_manager: *mut YrsBridgeUndoManager,
    out: *mut usize,
) -> i32 {
    ffi_boundary(|| {
        if undo_manager.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        *out = (*undo_manager).0.undo_stack().len();
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_redo_stack_len(
    undo_manager: *mut YrsBridgeUndoManager,
    out: *mut usize,
) -> i32 {
    ffi_boundary(|| {
        if undo_manager.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        *out = (*undo_manager).0.redo_stack().len();
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_observe_item_added(
    undo_manager: *mut YrsBridgeUndoManager,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if undo_manager.is_null() {
            return null_mut();
        }
        let context = context as usize;
        observation((*undo_manager).0.observe_item_added(move |_txn, event| {
            emit_json(
                callback,
                context,
                serde_json::json!({
                    "kind": "undoItemAdded",
                    "action": format!("{:?}", event.kind()).to_lowercase(),
                    "changedScopeCount": event.changed_parent_types().len(),
                }),
            );
        }))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_undo_manager_observe_item_popped(
    undo_manager: *mut YrsBridgeUndoManager,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if undo_manager.is_null() {
            return null_mut();
        }
        let context = context as usize;
        observation((*undo_manager).0.observe_item_popped(move |_txn, event| {
            emit_json(
                callback,
                context,
                serde_json::json!({
                    "kind": "undoItemPopped",
                    "action": format!("{:?}", event.kind()).to_lowercase(),
                    "changedScopeCount": event.changed_parent_types().len(),
                }),
            );
        }))
    }))
    .unwrap_or(null_mut())
}

fn awareness_event_json(kind: &str, event: &yrs::sync::awareness::Event) -> serde_json::Value {
    let client_ids = |ids: &[ClientID]| -> Vec<u64> { ids.iter().map(|id| id.get()).collect() };
    serde_json::json!({
        "kind": kind,
        "added": client_ids(event.added()),
        "updated": client_ids(event.updated()),
        "removed": client_ids(event.removed()),
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_new(doc: *mut Doc) -> *mut YrsBridgeAwareness {
    catch_unwind(AssertUnwindSafe(|| {
        if doc.is_null() {
            return null_mut();
        }
        Box::into_raw(Box::new(YrsBridgeAwareness(Awareness::new((*doc).clone()))))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_destroy(awareness: *mut YrsBridgeAwareness) {
    if !awareness.is_null() {
        drop(Box::from_raw(awareness));
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_client_id(
    awareness: *mut YrsBridgeAwareness,
) -> u64 {
    if awareness.is_null() {
        return 0;
    }
    (*awareness).0.client_id().get()
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_set_local_state_json(
    awareness: *mut YrsBridgeAwareness,
    state_json: *const c_char,
) -> i32 {
    ffi_boundary(|| {
        if awareness.is_null() || state_json.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let state_json = match read_name(state_json) {
            Ok(state_json) => state_json,
            Err(code) => return code,
        };
        if serde_json::from_str::<serde_json::Value>(&state_json).is_err() {
            return YRS_BRIDGE_ERR_DECODE;
        }
        (*awareness).0.set_local_state_raw(state_json);
        YRS_BRIDGE_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_clear_local_state(
    awareness: *mut YrsBridgeAwareness,
) {
    if !awareness.is_null() {
        (*awareness).0.clean_local_state();
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_remove_state(
    awareness: *mut YrsBridgeAwareness,
    client_id: u64,
) {
    if !awareness.is_null() {
        (*awareness).0.remove_state(ClientID::new(client_id));
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_local_state_json(
    awareness: *mut YrsBridgeAwareness,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if awareness.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(state) = (*awareness).0.local_state_raw() else {
            return write_buffer(Vec::new(), out);
        };
        write_buffer(state.as_bytes().to_vec(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_state_json(
    awareness: *mut YrsBridgeAwareness,
    client_id: u64,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if awareness.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let Some(state) = (*awareness).0.state::<serde_json::Value>(ClientID::new(client_id))
        else {
            return write_buffer(Vec::new(), out);
        };
        let Ok(bytes) = serde_json::to_vec(&state) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        write_buffer(bytes, out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_states_json(
    awareness: *mut YrsBridgeAwareness,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if awareness.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let mut states = Vec::new();
        for (client_id, state) in (*awareness).0.iter() {
            let data = match state.data {
                Some(data) => data,
                None => continue,
            };
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&data) else {
                return YRS_BRIDGE_ERR_DECODE;
            };
            states.push(serde_json::json!({
                "clientID": client_id.get(),
                "state": value,
            }));
        }
        let Ok(bytes) = serde_json::to_vec(&states) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        write_buffer(bytes, out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_encode_update(
    awareness: *mut YrsBridgeAwareness,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if awareness.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let update = match (*awareness).0.update() {
            Ok(update) => update,
            Err(_) => return YRS_BRIDGE_ERR_DECODE,
        };
        write_buffer(update.encode_v1(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_encode_update_for_clients(
    awareness: *mut YrsBridgeAwareness,
    client_ids: *const u64,
    client_ids_len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if awareness.is_null() || client_ids.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let client_ids = std::slice::from_raw_parts(client_ids, client_ids_len)
            .iter()
            .copied()
            .map(ClientID::new)
            .collect::<Vec<_>>();
        let update = match (*awareness).0.update_with_clients(client_ids) {
            Ok(update) => update,
            Err(_) => return YRS_BRIDGE_ERR_DECODE,
        };
        write_buffer(update.encode_v1(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_apply_update(
    awareness: *mut YrsBridgeAwareness,
    update: *const c_uchar,
    update_len: usize,
) -> i32 {
    ffi_boundary(|| {
        if awareness.is_null() || update.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = std::slice::from_raw_parts(update, update_len);
        let Ok(update) = AwarenessUpdate::decode_v1(bytes) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        match (*awareness).0.apply_update(update) {
            Ok(()) => YRS_BRIDGE_OK,
            Err(_) => YRS_BRIDGE_ERR_DECODE,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_observe_update(
    awareness: *mut YrsBridgeAwareness,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if awareness.is_null() {
            return null_mut();
        }
        let context = context as usize;
        observation((*awareness).0.on_update(move |_awareness, event, _origin| {
            emit_json(callback, context, awareness_event_json("awarenessUpdate", event));
        }))
    }))
    .unwrap_or(null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_awareness_observe_change(
    awareness: *mut YrsBridgeAwareness,
    context: *mut c_void,
    callback: YrsBridgeEventCallback,
) -> *mut YrsBridgeObservation {
    catch_unwind(AssertUnwindSafe(|| {
        if awareness.is_null() {
            return null_mut();
        }
        let context = context as usize;
        observation((*awareness).0.on_change(move |_awareness, event, _origin| {
            emit_json(callback, context, awareness_event_json("awarenessChange", event));
        }))
    }))
    .unwrap_or(null_mut())
}

fn encode_sync_messages(messages: impl IntoIterator<Item = Message>) -> Vec<u8> {
    let mut encoder = EncoderV1::new();
    for message in messages {
        message.encode(&mut encoder);
    }
    encoder.to_vec()
}

fn sync_message_json(message: Message) -> serde_json::Value {
    match message {
        Message::Sync(SyncMessage::SyncStep1(state_vector)) => serde_json::json!({
            "kind": "syncStep1",
            "stateVector": state_vector.encode_v1(),
        }),
        Message::Sync(SyncMessage::SyncStep2(update)) => serde_json::json!({
            "kind": "syncStep2",
            "update": update,
        }),
        Message::Sync(SyncMessage::Update(update)) => serde_json::json!({
            "kind": "update",
            "update": update,
        }),
        Message::Awareness(update) => serde_json::json!({
            "kind": "awareness",
            "update": update.encode_v1(),
        }),
        Message::AwarenessQuery => serde_json::json!({
            "kind": "awarenessQuery",
        }),
        Message::Auth(reason) => serde_json::json!({
            "kind": "auth",
            "reason": reason,
        }),
        Message::Custom(tag, data) => serde_json::json!({
            "kind": "custom",
            "tag": tag,
            "data": data,
        }),
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_sync_message_sync_step1(
    state_vector: *const c_uchar,
    state_vector_len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if state_vector.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = std::slice::from_raw_parts(state_vector, state_vector_len);
        let Ok(state_vector) = StateVector::decode_v1(bytes) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        write_buffer(
            encode_sync_messages([Message::Sync(SyncMessage::SyncStep1(state_vector))]),
            out,
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_sync_message_sync_step2(
    update: *const c_uchar,
    update_len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if update.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = std::slice::from_raw_parts(update, update_len);
        if Update::decode_v1(bytes).is_err() {
            return YRS_BRIDGE_ERR_DECODE;
        }
        write_buffer(
            encode_sync_messages([Message::Sync(SyncMessage::SyncStep2(bytes.to_vec()))]),
            out,
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_sync_message_update(
    update: *const c_uchar,
    update_len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if update.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = std::slice::from_raw_parts(update, update_len);
        if Update::decode_v1(bytes).is_err() {
            return YRS_BRIDGE_ERR_DECODE;
        }
        write_buffer(
            encode_sync_messages([Message::Sync(SyncMessage::Update(bytes.to_vec()))]),
            out,
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_sync_message_awareness(
    update: *const c_uchar,
    update_len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if update.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = std::slice::from_raw_parts(update, update_len);
        let Ok(update) = AwarenessUpdate::decode_v1(bytes) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        write_buffer(encode_sync_messages([Message::Awareness(update)]), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_sync_message_awareness_query(
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        write_buffer(encode_sync_messages([Message::AwarenessQuery]), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_sync_decode_messages(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if payload.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = std::slice::from_raw_parts(payload, payload_len);
        let mut decoder = DecoderV1::new(Cursor::new(bytes));
        let mut messages = Vec::new();
        loop {
            let Ok(remaining) = decoder.read_to_end() else {
                return YRS_BRIDGE_ERR_DECODE;
            };
            if remaining.is_empty() {
                break;
            }
            let Ok(message) = Message::decode(&mut decoder) else {
                return YRS_BRIDGE_ERR_DECODE;
            };
            messages.push(sync_message_json(message));
        }
        let Ok(bytes) = serde_json::to_vec(&messages) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        write_buffer(bytes, out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_sync_start(
    awareness: *mut YrsBridgeAwareness,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if awareness.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let mut encoder = EncoderV1::new();
        if DefaultProtocol.start(&(*awareness).0, &mut encoder).is_err() {
            return YRS_BRIDGE_ERR_DECODE;
        }
        write_buffer(encoder.to_vec(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_sync_handle(
    awareness: *mut YrsBridgeAwareness,
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if awareness.is_null() || payload.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = std::slice::from_raw_parts(payload, payload_len);
        let responses = match DefaultProtocol.handle(&mut (*awareness).0, bytes) {
            Ok(responses) => responses,
            Err(_) => return YRS_BRIDGE_ERR_DECODE,
        };
        write_buffer(encode_sync_messages(responses), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_lib0_encode_any(
    json: *const c_uchar,
    json_len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if json.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = std::slice::from_raw_parts(json, json_len);
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(bytes) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        let any = plain_any_from_json(value);
        let mut encoder = EncoderV1::new();
        encoder.write_any(&any);
        write_buffer(encoder.to_vec(), out)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrs_bridge_lib0_decode_any(
    bytes: *const c_uchar,
    bytes_len: usize,
    out: *mut YrsBridgeBuffer,
) -> i32 {
    ffi_boundary(|| {
        if bytes.is_null() || out.is_null() {
            return YRS_BRIDGE_ERR_NULL_POINTER;
        }
        let bytes = std::slice::from_raw_parts(bytes, bytes_len);
        let mut decoder = DecoderV1::new(Cursor::new(bytes));
        let Ok(any) = decoder.read_any() else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        let Ok(json) = serde_json::to_vec(&plain_json_from_any(&any)) else {
            return YRS_BRIDGE_ERR_DECODE;
        };
        write_buffer(json, out)
    })
}
