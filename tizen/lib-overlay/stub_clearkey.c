/* Stub libclearkey.so.0 — satisfies libgsthls.so's load-time DT_NEEDED on this
 * retail TV where the real /.../libclearkey.so.0 is EPERM-blocked. Bilibili live
 * HLS is UNENCRYPTED (no EXT-X-KEY), so libgsthls never calls these — they only
 * need to resolve at dlopen. All no-ops. */
void *clearkey_context_alloc(void) { return 0; }
void  clearkey_context_free(void *c) { (void)c; }
int   clearkey_se_init_ex(void *a, void *b, void *d) { (void)a;(void)b;(void)d; return 0; }
int   clearkey_se_process(void *a, void *b, void *d, void *e) { (void)a;(void)b;(void)d;(void)e; return 0; }
int   clearkey_se_final(void *a) { (void)a; return 0; }
int   clearkey_addkey_ex(void *a, void *b, void *d, void *e) { (void)a;(void)b;(void)d;(void)e; return 0; }
