#ifndef YRS_BRIDGE_FFI_H
#define YRS_BRIDGE_FFI_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct YrsBridgeDoc YrsBridgeDoc;
typedef struct YrsBridgeTransaction YrsBridgeTransaction;
typedef struct YrsBridgeBranch YrsBridgeBranch;
typedef struct YrsBridgeObservation YrsBridgeObservation;
typedef struct YrsBridgeUndoManager YrsBridgeUndoManager;
typedef struct YrsBridgeAwareness YrsBridgeAwareness;
typedef void (*YrsBridgeEventCallback)(void *_Nullable context, const unsigned char *_Nonnull data, unsigned long len);

typedef struct YrsBridgeBuffer {
    unsigned char *_Nullable data;
    unsigned long len;
} YrsBridgeBuffer;

typedef struct YrsBridgeValue {
    int tag;
    bool bool_value;
    int64_t int_value;
    double double_value;
    unsigned char *_Nullable bytes;
    unsigned long len;
    YrsBridgeBranch *_Nullable branch;
} YrsBridgeValue;

YrsBridgeDoc *_Nullable yrs_bridge_doc_new(void);
YrsBridgeDoc *_Nullable yrs_bridge_doc_new_with_client_id(uint64_t client_id);
uint64_t yrs_bridge_doc_client_id(YrsBridgeDoc *_Nonnull doc);
void yrs_bridge_doc_destroy(YrsBridgeDoc *_Nonnull doc);

int yrs_bridge_doc_read_transaction(YrsBridgeDoc *_Nonnull doc, YrsBridgeTransaction *_Nullable *_Nonnull out);
int yrs_bridge_doc_write_transaction(YrsBridgeDoc *_Nonnull doc, YrsBridgeTransaction *_Nullable *_Nonnull out);
int yrs_bridge_doc_write_transaction_with_origin(YrsBridgeDoc *_Nonnull doc, const char *_Nonnull origin, YrsBridgeTransaction *_Nullable *_Nonnull out);
void yrs_bridge_transaction_destroy(YrsBridgeTransaction *_Nonnull transaction);
int yrs_bridge_transaction_is_writable(YrsBridgeTransaction *_Nonnull transaction, bool *_Nonnull out);

int yrs_bridge_transaction_state_vector_v1(YrsBridgeTransaction *_Nonnull transaction, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_transaction_state_diff_v1(YrsBridgeTransaction *_Nonnull transaction, const unsigned char *_Nullable state_vector, unsigned long state_vector_len, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_transaction_state_diff_v2(YrsBridgeTransaction *_Nonnull transaction, const unsigned char *_Nullable state_vector, unsigned long state_vector_len, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_transaction_apply_v1(YrsBridgeTransaction *_Nonnull transaction, const unsigned char *_Nonnull update, unsigned long update_len);
int yrs_bridge_transaction_apply_v2(YrsBridgeTransaction *_Nonnull transaction, const unsigned char *_Nonnull update, unsigned long update_len);

void yrs_bridge_buffer_destroy(YrsBridgeBuffer buffer);

YrsBridgeBranch *_Nullable yrs_bridge_doc_get_text(YrsBridgeDoc *_Nonnull doc, const char *_Nonnull name);
YrsBridgeBranch *_Nullable yrs_bridge_doc_get_map(YrsBridgeDoc *_Nonnull doc, const char *_Nonnull name);
YrsBridgeBranch *_Nullable yrs_bridge_doc_get_array(YrsBridgeDoc *_Nonnull doc, const char *_Nonnull name);
YrsBridgeBranch *_Nullable yrs_bridge_doc_get_xml_fragment(YrsBridgeDoc *_Nonnull doc, const char *_Nonnull name);

int yrs_bridge_text_insert(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, const char *_Nonnull value);
int yrs_bridge_text_insert_with_attributes_json(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, const char *_Nonnull value, const char *_Nullable attributes_json);
int yrs_bridge_text_format_json(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, uint32_t len, const char *_Nonnull attributes_json);
int yrs_bridge_text_insert_embed(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, YrsBridgeValue value, const char *_Nullable attributes_json);
int yrs_bridge_text_apply_delta_json(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull delta_json);
int yrs_bridge_text_remove(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, uint32_t len);
int yrs_bridge_text_len(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t *_Nonnull out);
int yrs_bridge_text_string(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_text_chunks_json(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, YrsBridgeBuffer *_Nonnull out);

int yrs_bridge_map_set(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key, YrsBridgeValue value);
int yrs_bridge_map_set_map(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_map_set_array(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_map_set_text(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_map_get(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key, YrsBridgeValue *_Nonnull out);
int yrs_bridge_map_remove(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key);
int yrs_bridge_map_entries_json(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, YrsBridgeBuffer *_Nonnull out);

int yrs_bridge_array_insert(YrsBridgeBranch *_Nonnull array, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, YrsBridgeValue value);
int yrs_bridge_array_insert_map(YrsBridgeBranch *_Nonnull array, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_array_insert_array(YrsBridgeBranch *_Nonnull array, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_array_insert_text(YrsBridgeBranch *_Nonnull array, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_array_get(YrsBridgeBranch *_Nonnull array, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, YrsBridgeValue *_Nonnull out);
int yrs_bridge_array_remove(YrsBridgeBranch *_Nonnull array, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, uint32_t len);
int yrs_bridge_array_len(YrsBridgeBranch *_Nonnull array, YrsBridgeTransaction *_Nonnull transaction, uint32_t *_Nonnull out);
int yrs_bridge_array_values_json(YrsBridgeBranch *_Nonnull array, YrsBridgeTransaction *_Nonnull transaction, YrsBridgeBuffer *_Nonnull out);

int yrs_bridge_xml_len(YrsBridgeBranch *_Nonnull xml, YrsBridgeTransaction *_Nonnull transaction, uint32_t *_Nonnull out);
int yrs_bridge_xml_string(YrsBridgeBranch *_Nonnull xml, YrsBridgeTransaction *_Nonnull transaction, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_xml_insert_element(YrsBridgeBranch *_Nonnull xml, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, const char *_Nonnull name, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_xml_insert_text(YrsBridgeBranch *_Nonnull xml, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_xml_get(YrsBridgeBranch *_Nonnull xml, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, YrsBridgeValue *_Nonnull out);
int yrs_bridge_xml_remove(YrsBridgeBranch *_Nonnull xml, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, uint32_t len);
int yrs_bridge_xml_element_tag(YrsBridgeBranch *_Nonnull xml, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_xml_set_attribute(YrsBridgeBranch *_Nonnull xml, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key, YrsBridgeValue value);
int yrs_bridge_xml_get_attribute(YrsBridgeBranch *_Nonnull xml, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key, YrsBridgeValue *_Nonnull out);
int yrs_bridge_xml_remove_attribute(YrsBridgeBranch *_Nonnull xml, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key);
int yrs_bridge_xml_text_insert(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, const char *_Nonnull value);
int yrs_bridge_xml_text_remove(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, uint32_t len);
int yrs_bridge_xml_text_len(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t *_Nonnull out);
int yrs_bridge_xml_text_string(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, YrsBridgeBuffer *_Nonnull out);

int yrs_bridge_map_set_new_subdoc(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key, YrsBridgeBuffer *_Nonnull guid_out);
int yrs_bridge_map_get_subdoc_guid(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_map_load_subdoc(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key);
int yrs_bridge_map_clear_subdoc(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key);
int yrs_bridge_transaction_subdoc_guids(YrsBridgeTransaction *_Nonnull transaction, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_map_set_weak_link(YrsBridgeBranch *_Nonnull source_map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull source_key, YrsBridgeBranch *_Nonnull target_map, const char *_Nonnull target_key, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_map_get_weak_link(YrsBridgeBranch *_Nonnull map, YrsBridgeTransaction *_Nonnull transaction, const char *_Nonnull key, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_text_set_quote(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t start, uint32_t end, bool start_inclusive, bool end_inclusive, YrsBridgeBranch *_Nonnull target_map, const char *_Nonnull target_key, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_array_set_quote(YrsBridgeBranch *_Nonnull array, YrsBridgeTransaction *_Nonnull transaction, uint32_t start, uint32_t end, bool start_inclusive, bool end_inclusive, YrsBridgeBranch *_Nonnull target_map, const char *_Nonnull target_key, YrsBridgeBranch *_Nullable *_Nonnull out);
int yrs_bridge_weak_deref(YrsBridgeBranch *_Nonnull weak, YrsBridgeTransaction *_Nonnull transaction, YrsBridgeValue *_Nonnull out);
int yrs_bridge_weak_values_json(YrsBridgeBranch *_Nonnull weak, YrsBridgeTransaction *_Nonnull transaction, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_weak_string(YrsBridgeBranch *_Nonnull weak, YrsBridgeTransaction *_Nonnull transaction, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_text_relative_position_json(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, int assoc, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_text_relative_position_v1(YrsBridgeBranch *_Nonnull text, YrsBridgeTransaction *_Nonnull transaction, uint32_t index, int assoc, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_relative_position_json_from_v1(const unsigned char *_Nonnull data, unsigned long len, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_relative_position_v1_from_json(const unsigned char *_Nonnull data, unsigned long len, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_relative_position_offset(const unsigned char *_Nonnull json, unsigned long len, YrsBridgeTransaction *_Nonnull transaction, uint32_t *_Nonnull out);
void yrs_bridge_value_destroy(YrsBridgeValue value);

void yrs_bridge_observation_destroy(YrsBridgeObservation *_Nonnull observation);
YrsBridgeObservation *_Nullable yrs_bridge_doc_observe_update_v1(YrsBridgeDoc *_Nonnull doc, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);
YrsBridgeObservation *_Nullable yrs_bridge_doc_observe_subdocs(YrsBridgeDoc *_Nonnull doc, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);
YrsBridgeObservation *_Nullable yrs_bridge_doc_observe_transaction_cleanup(YrsBridgeDoc *_Nonnull doc, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);
YrsBridgeObservation *_Nullable yrs_bridge_doc_observe_destroy(YrsBridgeDoc *_Nonnull doc, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);
YrsBridgeObservation *_Nullable yrs_bridge_text_observe(YrsBridgeBranch *_Nonnull text, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);
YrsBridgeObservation *_Nullable yrs_bridge_array_observe(YrsBridgeBranch *_Nonnull array, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);
YrsBridgeObservation *_Nullable yrs_bridge_map_observe(YrsBridgeBranch *_Nonnull map, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);
YrsBridgeObservation *_Nullable yrs_bridge_xml_observe(YrsBridgeBranch *_Nonnull xml, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);
YrsBridgeObservation *_Nullable yrs_bridge_xml_text_observe(YrsBridgeBranch *_Nonnull text, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);
YrsBridgeObservation *_Nullable yrs_bridge_weak_observe(YrsBridgeBranch *_Nonnull weak, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);

YrsBridgeUndoManager *_Nullable yrs_bridge_undo_manager_new(void);
void yrs_bridge_undo_manager_destroy(YrsBridgeUndoManager *_Nonnull undo_manager);
int yrs_bridge_undo_manager_add_scope(YrsBridgeUndoManager *_Nonnull undo_manager, YrsBridgeDoc *_Nonnull doc, YrsBridgeBranch *_Nonnull branch);
int yrs_bridge_undo_manager_include_origin(YrsBridgeUndoManager *_Nonnull undo_manager, const char *_Nonnull origin);
int yrs_bridge_undo_manager_exclude_origin(YrsBridgeUndoManager *_Nonnull undo_manager, const char *_Nonnull origin);
int yrs_bridge_undo_manager_undo(YrsBridgeUndoManager *_Nonnull undo_manager, bool *_Nonnull out);
int yrs_bridge_undo_manager_redo(YrsBridgeUndoManager *_Nonnull undo_manager, bool *_Nonnull out);
void yrs_bridge_undo_manager_stop(YrsBridgeUndoManager *_Nonnull undo_manager);
void yrs_bridge_undo_manager_clear(YrsBridgeUndoManager *_Nonnull undo_manager);
int yrs_bridge_undo_manager_undo_stack_len(YrsBridgeUndoManager *_Nonnull undo_manager, unsigned long *_Nonnull out);
int yrs_bridge_undo_manager_redo_stack_len(YrsBridgeUndoManager *_Nonnull undo_manager, unsigned long *_Nonnull out);
YrsBridgeObservation *_Nullable yrs_bridge_undo_manager_observe_item_added(YrsBridgeUndoManager *_Nonnull undo_manager, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);
YrsBridgeObservation *_Nullable yrs_bridge_undo_manager_observe_item_popped(YrsBridgeUndoManager *_Nonnull undo_manager, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);

YrsBridgeAwareness *_Nullable yrs_bridge_awareness_new(YrsBridgeDoc *_Nonnull doc);
void yrs_bridge_awareness_destroy(YrsBridgeAwareness *_Nonnull awareness);
uint64_t yrs_bridge_awareness_client_id(YrsBridgeAwareness *_Nonnull awareness);
int yrs_bridge_awareness_set_local_state_json(YrsBridgeAwareness *_Nonnull awareness, const char *_Nonnull state_json);
void yrs_bridge_awareness_clear_local_state(YrsBridgeAwareness *_Nonnull awareness);
void yrs_bridge_awareness_remove_state(YrsBridgeAwareness *_Nonnull awareness, uint64_t client_id);
int yrs_bridge_awareness_local_state_json(YrsBridgeAwareness *_Nonnull awareness, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_awareness_state_json(YrsBridgeAwareness *_Nonnull awareness, uint64_t client_id, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_awareness_states_json(YrsBridgeAwareness *_Nonnull awareness, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_awareness_encode_update(YrsBridgeAwareness *_Nonnull awareness, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_awareness_encode_update_for_clients(YrsBridgeAwareness *_Nonnull awareness, const uint64_t *_Nonnull client_ids, unsigned long client_ids_len, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_awareness_apply_update(YrsBridgeAwareness *_Nonnull awareness, const unsigned char *_Nonnull update, unsigned long update_len);
YrsBridgeObservation *_Nullable yrs_bridge_awareness_observe_update(YrsBridgeAwareness *_Nonnull awareness, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);
YrsBridgeObservation *_Nullable yrs_bridge_awareness_observe_change(YrsBridgeAwareness *_Nonnull awareness, void *_Nullable context, YrsBridgeEventCallback _Nonnull callback);

int yrs_bridge_sync_message_sync_step1(const unsigned char *_Nonnull state_vector, unsigned long state_vector_len, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_sync_message_sync_step2(const unsigned char *_Nonnull update, unsigned long update_len, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_sync_message_update(const unsigned char *_Nonnull update, unsigned long update_len, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_sync_message_awareness(const unsigned char *_Nonnull update, unsigned long update_len, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_sync_message_awareness_query(YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_sync_decode_messages(const unsigned char *_Nonnull payload, unsigned long payload_len, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_sync_start(YrsBridgeAwareness *_Nonnull awareness, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_sync_handle(YrsBridgeAwareness *_Nonnull awareness, const unsigned char *_Nonnull payload, unsigned long payload_len, YrsBridgeBuffer *_Nonnull out);

int yrs_bridge_lib0_encode_any(const unsigned char *_Nonnull json, unsigned long json_len, YrsBridgeBuffer *_Nonnull out);
int yrs_bridge_lib0_decode_any(const unsigned char *_Nonnull bytes, unsigned long bytes_len, YrsBridgeBuffer *_Nonnull out);

#ifdef __cplusplus
}
#endif

#endif
