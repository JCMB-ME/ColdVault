#ifndef COLDVAULT_TOR_LOCAL_H
#define COLDVAULT_TOR_LOCAL_H

/// Runs Tor with these command-line options (without the program name) on the
/// calling thread; returns when Tor exits. Call it from a dedicated thread.
int coldvault_tor_run(int argc, const char *const *argv);

#endif
