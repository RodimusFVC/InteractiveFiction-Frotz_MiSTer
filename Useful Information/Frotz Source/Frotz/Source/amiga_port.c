/* Shared I/O for Amiga Frotz. The core owns the returned story stream. */
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <errno.h>
#include "frotz.h"
#include "amiga_port.h"
#include "blorblow.h"

static long story_start;
static long story_length;

FILE *amiga_load_story(const char *name, bb_map_t **map)
{
    FILE *file = fopen(name, "rb");
    bb_result_t result;
    long length;
    unsigned char magic[4];

    story_start = story_length = 0;
    if (!file)
        return NULL;
    if (fseek(file, 0, SEEK_END) || (length = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET))
        goto failed;
    story_length = length;
    if (fread(magic, 1, sizeof(magic), file) != sizeof(magic))
        goto failed;
    if (memcmp(magic, "FORM", 4) == 0) {
        if (bb_create_map(file, map) != bb_err_None)
            goto failed;
        if (bb_load_resource(*map, bb_method_FilePos, &result,
                             bb_ID_Exec, 0) != bb_err_None ||
            (*map)->chunks[result.chunknum].type != bb_make_id('Z','C','O','D') ||
            result.data.startpos > (unsigned long)length ||
            result.length > (unsigned long)length - result.data.startpos)
            goto failed;
        story_start = result.data.startpos;
        story_length = result.length;
    }
    if (fseek(file, story_start, SEEK_SET))
        goto failed;
    return file;

failed:
    if (*map) {
        bb_destroy_map(*map);
        *map = NULL;
    }
    fclose(file);
    return NULL;
}

int os_storyfile_seek(FILE *file, long offset, int whence)
{
    long base, position;
    switch (whence) {
    case SEEK_SET: base = 0; break;
    case SEEK_CUR:
        position = ftell(file);
        if (position < story_start)
            return -1;
        base = position - story_start;
        break;
    case SEEK_END: base = story_length; break;
    default: errno = EINVAL; return -1;
    }
    /* Check before adding, including LONG_MIN offsets. */
    if (base < 0 || base > story_length ||
        offset < -base || offset > story_length - base) {
        errno = EINVAL;
        return -1;
    }
    return fseek(file, story_start + base + offset, SEEK_SET);
}

int os_storyfile_tell(FILE *file)
{
    long position = ftell(file);
    if (position < story_start || position - story_start > INT_MAX)
        return -1;
    return (int)(position - story_start);
}

char *amiga_file_part(const char *path)
{
    const char *part = path;
    while (*path) {
        if (*path == '/' || *path == ':')
            part = path + 1;
        ++path;
    }
    return (char *)part;
}

char *amiga_with_extension(const char *path, const char *extension)
{
    const char *dot = strrchr(amiga_file_part(path), '.');
    size_t length = dot ? (size_t)(dot - path) : strlen(path);
    char *result = malloc(length + strlen(extension) + 1);
    if (!result)
        os_fatal("Out of memory");
    memcpy(result, path, length);
    strcpy(result + length, extension);
    return result;
}

char *amiga_join_path(const char *directory, const char *name)
{
    size_t length = strlen(directory);
    int slash = length && directory[length-1] != ':' && directory[length-1] != '/';
    char *result = malloc(length + slash + strlen(name) + 1);
    if (!result)
        os_fatal("Out of memory");
    memcpy(result, directory, length);
    if (slash)
        result[length++] = '/';
    strcpy(result + length, name);
    return result;
}

void amiga_init_file_names(const char *story)
{
    f_setup.save_name = amiga_with_extension(story, ".Save");
    f_setup.script_name = amiga_with_extension(amiga_file_part(story), ".Script");
    f_setup.command_name = amiga_with_extension(story, ".Record");
    f_setup.aux_name = amiga_with_extension(story, ".Aux");
}

zword amiga_rgb15(unsigned short colour)
{
    unsigned int r = (colour >> 8) & 15;
    unsigned int g = (colour >> 4) & 15;
    unsigned int b = colour & 15;
    r = (r << 1) | (r >> 3);
    g = (g << 1) | (g >> 3);
    b = (b << 1) | (b >> 3);
    return r | (g << 5) | (b << 10);
}

int amiga_nearest_colour(zword colour, const unsigned short *palette, int count)
{
    int i, best = BLACK_COLOUR;
    long best_distance = LONG_MAX;
    for (i = 0; i < count; ++i) {
        zword candidate = amiga_rgb15(palette[i]);
        int r = (int)(colour & 31) - (int)(candidate & 31);
        int g = (int)((colour >> 5) & 31) - (int)((candidate >> 5) & 31);
        int b = (int)((colour >> 10) & 31) - (int)((candidate >> 10) & 31);
        long distance = r*r + g*g + b*b;
        if (distance < best_distance) {
            best_distance = distance;
            best = BLACK_COLOUR + i;
        }
    }
    return best;
}
