#include "YLRime.h"
#include "rime_api.h"
#include <stdlib.h>
#include <string.h>
static RimeApi *api;
int yl_start(const char *shared, const char *user, int deploy) {
    if (api) return 1;
    api = rime_get_api();
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared;
    traits.user_data_dir = user;
    traits.distribution_name = "LinkInput";
    traits.distribution_code_name = "yiliu";
    traits.distribution_version = "0.1.0";
    traits.app_name = "rime.yiliu";
    traits.min_log_level = 3;
    traits.log_dir = "";
    api->setup(&traits);
    api->initialize(&traits);
    if (deploy && api->start_maintenance(True)) api->join_maintenance_thread();
    return 1;
}
int yl_deploy(const char *path) { return api && api->deploy_schema(path); }
void yl_stop(void) { if (api) { api->finalize(); api = NULL; } }
uintptr_t yl_session(void) { return api ? api->create_session() : 0; }
void yl_destroy(uintptr_t s) { if (api) api->destroy_session(s); }
int yl_schema(uintptr_t s, const char *schema) {
    if (!api) return 0;
    api->clear_composition(s);
    int ok = api->select_schema(s, schema);
    api->set_option(s, "simplification", True);
    return ok;
}
void yl_ascii(uintptr_t s, int enabled) { api->set_option(s, "ascii_mode", enabled); }
int yl_is_ascii(uintptr_t s) { return api->get_option(s, "ascii_mode"); }
int yl_key(uintptr_t s, int key, int modifiers) { return api->process_key(s, key, modifiers); }
const char *yl_input(uintptr_t s) { return api->get_input(s); }
void yl_clear(uintptr_t s) { api->clear_composition(s); }
int yl_select(uintptr_t s, int index) { return api->select_candidate_on_current_page(s, index); }
int yl_highlight(uintptr_t s, int index) { return index >= 0 && api->highlight_candidate(s, (size_t)index); }
int yl_select_absolute(uintptr_t s, int index) { return index >= 0 && api->select_candidate(s, (size_t)index); }
YLState *yl_candidates(uintptr_t s, int start, int count) {
    YLState *out = calloc(1, sizeof(YLState));
    out->last_page = 1;
    if (start < 0 || count < 1 || count > 100) return out;
    RimeCandidateListIterator iterator = {0};
    if (!api->candidate_list_from_index(s, &iterator, start)) return out;
    out->candidates = calloc(count, sizeof(char *));
    while (out->count < count && api->candidate_list_next(&iterator)) {
        out->candidates[out->count++] = strdup(iterator.candidate.text ?: "");
    }
    if (out->count == count) out->last_page = !api->candidate_list_next(&iterator);
    api->candidate_list_end(&iterator);
    return out;
}
YLState *yl_state(uintptr_t s) {
    YLState *out = calloc(1, sizeof(YLState));
    out->input = strdup(api->get_input(s) ?: "");
    out->input_cursor_bytes = (int)api->get_caret_pos(s);
    RIME_STRUCT(RimeContext, ctx);
    if (api->get_context(s, &ctx)) {
        out->preedit = strdup(ctx.composition.preedit ?: "");
        out->cursor_bytes = ctx.composition.cursor_pos;
        out->count = ctx.menu.num_candidates;
        out->highlighted = ctx.menu.highlighted_candidate_index;
        out->page = ctx.menu.page_no;
        out->last_page = ctx.menu.is_last_page;
        out->candidates = calloc(out->count, sizeof(char *));
        for (int i = 0; i < out->count; i++) out->candidates[i] = strdup(ctx.menu.candidates[i].text ?: "");
        api->free_context(&ctx);
    }
    RIME_STRUCT(RimeCommit, commit);
    if (api->get_commit(s, &commit)) {
        out->commit = strdup(commit.text ?: "");
        api->free_commit(&commit);
    }
    return out;
}
void yl_free_state(YLState *out) {
    free(out->preedit); free(out->input); free(out->commit);
    for (int i = 0; i < out->count; i++) free(out->candidates[i]);
    free(out->candidates); free(out);
}
void yl_sync(void) { if (api) api->sync_user_data(); }
