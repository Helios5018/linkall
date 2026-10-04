#ifndef YL_RIME_H
#define YL_RIME_H
#include <stdint.h>
typedef struct {
    char *preedit;
    char *input;
    int input_cursor_bytes;
    char *commit;
    char **candidates;
    int count;
    int highlighted;
    int page;
    int last_page;
    int cursor_bytes;
} YLState;
int yl_start(const char *shared, const char *user, int deploy);
void yl_stop(void);
int yl_deploy(const char *path);
uintptr_t yl_session(void);
void yl_destroy(uintptr_t session);
int yl_schema(uintptr_t session, const char *schema);
void yl_ascii(uintptr_t session, int enabled);
int yl_is_ascii(uintptr_t session);
int yl_key(uintptr_t session, int key, int modifiers);
const char *yl_input(uintptr_t session);
void yl_clear(uintptr_t session);
int yl_select(uintptr_t session, int index);
int yl_highlight(uintptr_t session, int index);
int yl_select_absolute(uintptr_t session, int index);
YLState *yl_candidates(uintptr_t session, int start, int count);
YLState *yl_state(uintptr_t session);
void yl_free_state(YLState *state);
void yl_sync(void);
#endif
