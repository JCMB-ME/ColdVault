#include "TorLocal.h"
#include <stdlib.h>
#include <string.h>

/* Tor's public embedding API (src/feature/api/tor_api.h). */
typedef struct tor_main_configuration_t tor_main_configuration_t;
tor_main_configuration_t *tor_main_configuration_new(void);
int tor_main_configuration_set_command_line(tor_main_configuration_t *cfg, int argc, char *argv[]);
int tor_run_main(const tor_main_configuration_t *cfg);
void tor_main_configuration_free(tor_main_configuration_t *cfg);

int coldvault_tor_run(int argc, const char *const *argv) {
    /* Tor keeps pointers to argv while it runs: give it its own copies. */
    char **copy = calloc((size_t)argc + 2, sizeof(char *));
    if (copy == NULL) return -1;
    copy[0] = strdup("tor");
    for (int i = 0; i < argc; i++) copy[i + 1] = strdup(argv[i]);

    tor_main_configuration_t *cfg = tor_main_configuration_new();
    if (cfg == NULL) return -1;
    tor_main_configuration_set_command_line(cfg, argc + 1, copy);
    int result = tor_run_main(cfg);
    tor_main_configuration_free(cfg);

    for (int i = 0; i < argc + 1; i++) free(copy[i]);
    free(copy);
    return result;
}
