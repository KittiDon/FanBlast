// Read-only SMC access for the FanBlast menu bar app.
// Reads need no privileges; all writes go through the existing root helper
// over /var/run/com.kirtan.friday.fan.sock, so nothing here is setuid.

#ifndef FANBLAST_BRIDGE_H
#define FANBLAST_BRIDGE_H

int    smc_start(void);                  // 0 on success
void   smc_stop(void);
double smc_number(const char *key);      // -1.0 when the key is absent/undecodable

#endif
