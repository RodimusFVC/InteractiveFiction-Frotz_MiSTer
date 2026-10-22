/* Shared, OS-independent support for the Amiga frontends. */
#ifndef AMIGA_PORT_H
#define AMIGA_PORT_H

#include "blorb.h"

FILE *amiga_load_story(const char *name, bb_map_t **map);
char *amiga_file_part(const char *path);
char *amiga_with_extension(const char *path, const char *extension);
char *amiga_join_path(const char *directory, const char *name);
void amiga_init_file_names(const char *story);
zword amiga_rgb15(unsigned short rgb12);
int amiga_nearest_colour(zword rgb15, const unsigned short *palette, int count);

#endif
