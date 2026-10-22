/*
 * amiga_sound.c
 *
 * Changes to distributed source are indicated by comments containing
 * the keyword AMIGA.
 *
 * Frotz is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * Frotz is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA
 *
 */

#include <proto/dos.h>
#include <proto/exec.h>
#include <devices/audio.h>
#include <clib/alib_protos.h>
#include <exec/exec.h>
#include <graphics/gfxbase.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "frotz.h"
#include "blorb.h"
#include "blorblow.h"
#include "amiga.h"
#include "amiga_port.h"
#include <limits.h>

struct SampleHeader
{
  unsigned short Length;
  unsigned char	 Times;
  unsigned char  BaseNote;
  unsigned short Frequency;
  unsigned char	 Blank[2];
  unsigned short SampleLength;
};

struct MacintoshMid
{
  unsigned short Length;
  unsigned char	 Commands[11];
  unsigned char  SoundFileName[19];
};

#define UNSIGNED_OFFSET 68

struct IOAudio *SoundRequest, *SoundLeftRequest, *SoundRightRequest;
int SampleFrequency, SampleOffset, SampleLength;
int SoundOpenCode = -1;
int CurrentSample, SampleUnsigned, SamplePlaying, SampleLoops;
char *SampleMemory;
char *SoundDirectory;

extern struct GfxBase *GfxBase;
extern struct MsgPort *SoundMsgPort;
extern int current_game;
extern bb_map_t* BlorbMap;

static double ReadAIFFExtended(const unsigned char *bytes);
static unsigned long ReadAIFFLong(const char *p)
{
  const unsigned char *b = (const unsigned char *)p;
  return ((unsigned long)b[0]<<24) | ((unsigned long)b[1]<<16) |
         ((unsigned long)b[2]<<8) | b[3];
}

/*
 * os_finish_with_sample
 *
 * Remove the current sample from memory (if any).
 *
 */

void os_finish_with_sample (int UNUSED(number))
{
  os_stop_sample(0);

  if (CurrentSample != 0)
  {
    if (SampleMemory != 0)
    {
      FreeVec(SampleMemory);
      SampleMemory = 0;
    }
    CurrentSample = 0;
  }
}

/*
 * os_prepare_sample
 *
 * Load the given sample from the disk.
 *
 */

void os_prepare_sample(int number)
{
  BPTR file;
  if (number <= 0 || CurrentSample == number) return;
  os_finish_with_sample(0);
  SampleUnsigned = 0;
  file = OpenSoundData(number);
  if (file) {
    struct FileInfoBlock *fib = AllocDosObject(DOS_FIB,0);
    if (fib) {
      if (ExamineFH(file,fib) && fib->fib_Size >= sizeof(struct SampleHeader)) {
        long length = fib->fib_Size;
        SampleMemory = AllocVec(length,MEMF_CHIP);
        if (SampleMemory) {
          struct SampleHeader *header = (struct SampleHeader *)SampleMemory;
          if (Read(file,SampleMemory,length) == length && header->Frequency &&
              header->SampleLength && header->SampleLength <= length - sizeof(*header)) {
            SampleFrequency = header->Frequency;
            SampleOffset = sizeof(*header);
            SampleLength = header->SampleLength;
          } else {
            FreeVec(SampleMemory);
            SampleMemory = NULL;
          }
        }
      }
      FreeDosObject(DOS_FIB,fib);
    }
    Close(file);
  }
  if (!SampleMemory && BlorbMap) {
    bb_result_t res;
    bb_aux_sound_t *info = NULL;
    if (bb_load_resource_snd(BlorbMap,bb_method_FilePos,&res,number,&info) == bb_err_None &&
        BlorbMap->chunks[res.chunknum].type == bb_make_id('F','O','R','M') &&
        res.length >= 12 && res.length <= INT_MAX) {
      SampleMemory = AllocVec(res.length,MEMF_CHIP);
      if (SampleMemory) {
        /* The map's stream works for embedded and standalone resources.
           Preserve its position; the Z-machine core owns embedded streams. */
        FILE *stream = BlorbMap->file;
        long position = ftell(stream);
        int loaded = position >= 0 && !fseek(stream,res.data.startpos,SEEK_SET) &&
                     fread(SampleMemory,1,res.length,stream) == res.length;
        if (position >= 0 && fseek(stream,position,SEEK_SET)) loaded = 0;
        if (loaded) {
          SampleUnsigned = 0;
          OpenAIFF(res.length);
        } else {
          FreeVec(SampleMemory);
          SampleMemory = NULL;
        }
      }
    }
  }
  if (!SampleMemory) return;
  CurrentSample = number;
  if (SampleUnsigned) {
    int i;
    for (i = 0; i < SampleLength; ++i)
      SampleMemory[SampleOffset+i] ^= 0x80;
  }
}

/*
 * os_start_sample
 *
 * Play the given sample at the given volume (ranging from 1 to 8 and
 * 255 meaning a default volume). The sound is played once or several
 * times in the background (255 meaning forever). The end_of_sound
 * function is called as soon as the sound finishes.
 *
 */

void os_start_sample (int number, int volume, int repeats, zword UNUSED(eos))
{
unsigned long rate;
int start = 0;

  if (SoundOpenCode != 0) return;
  os_stop_sample(0);
  os_prepare_sample(number);

  if (CurrentSample == 0) return;

  if (repeats == 0)
    repeats = 1;

  if (volume == 255) volume = 8;
  if (volume < 1) volume = 1;
  if (volume > 8) volume = 8;
  if (repeats == 255) repeats = 0; /* audio.device: zero cycles repeats forever. */

  rate = (GfxBase->DisplayFlags&PAL ? 3546895 : 3579545) / SampleFrequency;

  SampleLoops = 0;
  while (start < SampleLength)
  {
    int length = SampleLength-start;
    if (length > 102400)
    {
      length = 102400;
      repeats = 1;
    }
    SampleLoops += 2;

    SoundLeftRequest->ioa_Request.io_Command = CMD_WRITE;
    SoundLeftRequest->ioa_Request.io_Flags = ADIOF_PERVOL;
    SoundLeftRequest->ioa_Period = rate;
    SoundLeftRequest->ioa_Volume = volume * 8;
    SoundLeftRequest->ioa_Cycles = repeats;
    SoundLeftRequest->ioa_Data = SampleMemory+SampleOffset+start;
    SoundLeftRequest->ioa_Length = length;
    if (SampleUnsigned)
    {
      if (start == 0)
	SoundLeftRequest->ioa_Data += UNSIGNED_OFFSET;
      if (start+length == SampleLength)
      {
	if (SoundLeftRequest->ioa_Length > (UNSIGNED_OFFSET*2))
	  SoundLeftRequest->ioa_Length -= (UNSIGNED_OFFSET*2);
      }
    }
    BeginIO(&SoundLeftRequest->ioa_Request);

    SoundRightRequest->ioa_Request.io_Command = CMD_WRITE;
    SoundRightRequest->ioa_Request.io_Flags = ADIOF_PERVOL;
    SoundRightRequest->ioa_Period = rate;
    SoundRightRequest->ioa_Volume = volume * 8;
    SoundRightRequest->ioa_Cycles = repeats;
    SoundRightRequest->ioa_Data = SampleMemory+SampleOffset+start;
    SoundRightRequest->ioa_Length = length;
    if (SampleUnsigned)
    {
      if (start == 0)
	SoundRightRequest->ioa_Data += UNSIGNED_OFFSET;
      if (start+length == SampleLength)
      {
	if (SoundRightRequest->ioa_Length > (UNSIGNED_OFFSET*2))
	  SoundRightRequest->ioa_Length -= (UNSIGNED_OFFSET*2);
      }
    }
    BeginIO(&SoundRightRequest->ioa_Request);

    start += length;
  }

  SamplePlaying = 1;
}

/*
 * os_stop_sample
 *
 * Turn off the current sample.
 *
 */

void os_stop_sample (int UNUSED(number))
{
  if (SoundOpenCode != 0) return;

  SoundLeftRequest->ioa_Request.io_Command = CMD_FLUSH;
  BeginSoundIO(SoundLeftRequest);

  SoundRightRequest->ioa_Request.io_Command = CMD_FLUSH;
  BeginSoundIO(SoundRightRequest);

  while (GetMsg(SoundMsgPort));

  SamplePlaying = 0;
  SampleLoops = 0;
}

int InitializeSound(void)
{
  SetupSoundDirectory();

  if ((SoundRequest = (struct IOAudio *)
    CreateIORequest(SoundMsgPort,sizeof(struct IOAudio))) == 0) return 0;
  if ((SoundLeftRequest = (struct IOAudio *)
    CreateIORequest(SoundMsgPort,sizeof(struct IOAudio))) == 0) return 0;
  if ((SoundRightRequest = (struct IOAudio *)
    CreateIORequest(SoundMsgPort,sizeof(struct IOAudio))) == 0) return 0;

static unsigned char allocation_map[] = { 3,5,10,12 };

  SoundRequest->ioa_Request.io_Message.mn_Node.ln_Pri = 127;
  SoundRequest->ioa_Request.io_Command = ADCMD_ALLOCATE;
  SoundRequest->ioa_Request.io_Flags = ADIOF_NOWAIT;
  SoundRequest->ioa_Data = allocation_map;
  SoundRequest->ioa_Length = sizeof(allocation_map);

  if ((SoundOpenCode =
    OpenDevice("audio.device",0,(struct IORequest *)SoundRequest,0)) != 0) return 0;

unsigned long channels;

  channels = (unsigned long)SoundRequest->ioa_Request.io_Unit;
  CopyMem(SoundRequest,SoundLeftRequest,sizeof(struct IOAudio));
  SoundLeftRequest->ioa_Request.io_Unit = (void *)(channels & 9);
  CopyMem(SoundRequest,SoundRightRequest,sizeof(struct IOAudio));
  SoundRightRequest->ioa_Request.io_Unit = (void *)(channels & 6);

  return 1;
}

void ResetSound(void)
{
  os_finish_with_sample(0);
  if (SoundOpenCode == 0) CloseDevice((struct IORequest *)SoundRequest);
  if (SoundRequest) DeleteIORequest(SoundRequest);
  if (SoundLeftRequest) DeleteIORequest(SoundLeftRequest);
  if (SoundRightRequest) DeleteIORequest(SoundRightRequest);

  SoundOpenCode = -1;
  SoundRequest = 0;
  SoundLeftRequest = 0;
  SoundRightRequest = 0;
  free(SoundDirectory);
  SoundDirectory = NULL;
}

void BeginSoundIO(struct IOAudio *AudioRequest)
{
  AudioRequest->ioa_Request.io_Flags = IOF_QUICK;
  BeginIO(AudioRequest);

  if ((AudioRequest->ioa_Request.io_Flags & IOF_QUICK) == 0)
    WaitForMsg(SoundMsgPort);
}

void SetupSoundDirectory(void)
{
  char *directory = strdup(f_setup.story_name);
  const char *special = current_game == 14 ? "LurkingHorrorSound" :
                        current_game == 20 ? "SherlockSound" : NULL;
  BPTR lock;
  if (!directory) os_fatal("Out of memory");
  *amiga_file_part(directory) = 0;
  free(SoundDirectory);
  SoundDirectory = NULL;
  if (special) {
    SoundDirectory = amiga_join_path(directory,special);
    if ((lock = Lock(SoundDirectory,ACCESS_READ))) {
      UnLock(lock);
      free(directory);
      return;
    }
    free(SoundDirectory);
  }
  SoundDirectory = amiga_join_path(directory,"Sound");
  free(directory);
}

/* Keep path construction separate from the small, bounded resource names. */
static BPTR OpenSoundName(const char *name)
{
  char *path;
  BPTR file;
  if (!SoundDirectory) return 0;
  path = amiga_join_path(SoundDirectory,name);
  file = Open(path,MODE_OLDFILE);
  free(path);
  return file;
}

BPTR OpenSoundData(int number)
{
  BPTR file, result;
  char name[40];
  char sample[MAX_FILE_NAME+1];
  struct MacintoshMid mac;
  int c;
  size_t length;

  sprintf(name,"s%d.nam",number);
  if ((file = OpenSoundName(name))) {
    if (Seek(file,2,OFFSET_BEGINNING) == -1) { Close(file); return 0; }
    for (length = 0; ; ++length) {
      c = FGetC(file);
      if (c == -1 || length >= sizeof(sample)) { Close(file); return 0; }
      sample[length] = (char)c;
      if (!c) break;
    }
    Close(file);
    if (!length) return 0;
    if ((result = OpenSoundName(sample))) return result;
  } else {
    sprintf(name,"s%d.dat",number);
    if ((result = OpenSoundName(name))) return result;
  }
  sprintf(name,"s%d",number);
  if ((result = OpenSoundName(name))) { SampleUnsigned = 1; return result; }
  sprintf(name,"m%d",number);
  if ((file = OpenSoundName(name))) {
    int valid = Read(file,&mac,sizeof(mac)) == sizeof(mac);
    Close(file);
    if (!valid || !memchr(mac.SoundFileName,0,sizeof(mac.SoundFileName))) return 0;
    SampleUnsigned = 1;
    return OpenSoundName((char *)mac.SoundFileName);
  }
  if (current_game == 14) sprintf(name,"lurkin%.2d.snd",number);
  else if (current_game == 20) sprintf(name,"sherlo%.2d.snd",number);
  else return 0;
  result = OpenSoundName(name);
  if (result) SampleUnsigned = 1;
  return result;
}

void OpenAIFF(int length)
{
  char *comm, *sound;
  unsigned long samples, offset, size;
  double frequency;
  if (length < 12 || memcmp(SampleMemory,"FORM",4) || memcmp(SampleMemory+8,"AIFF",4))
    goto invalid;
  comm = FindAIFFChunk("COMM",length);
  sound = FindAIFFChunk("SSND",length);
  if (!comm || !sound || ReadAIFFLong(comm-4) < 18 || ReadAIFFLong(sound-4) < 8)
    goto invalid;
  if ((unsigned char)comm[0] != 0 || (unsigned char)comm[1] != 1 ||
      (unsigned char)comm[6] != 0 || (unsigned char)comm[7] != 8)
    goto invalid;
  samples = ReadAIFFLong(comm+2);
  frequency = ReadAIFFExtended((unsigned char *)comm+8);
  size = ReadAIFFLong(sound-4) - 8;
  offset = ReadAIFFLong(sound);
  if (!(frequency >= 1 && frequency <= 65535) || !samples ||
      samples > INT_MAX || offset > size || samples > size-offset)
    goto invalid;
  SampleFrequency = (int)frequency;
  SampleOffset = (sound - SampleMemory) + 8 + offset;
  SampleLength = samples;
  return;
invalid:
  FreeVec(SampleMemory);
  SampleMemory = NULL;
}


char *FindAIFFChunk(const char *chunk, int length)
{
  unsigned long pos = 12, size, form;
  if (length < 12) return NULL;
  form = ReadAIFFLong(SampleMemory+4);
  if (form < 4 || form > (unsigned long)length-8) return NULL;
  length = form + 8;
  while (pos <= (unsigned long)length && (unsigned long)length-pos >= 8) {
    size = ReadAIFFLong(SampleMemory+pos+4);
    if (size > (unsigned long)length-pos-8) return NULL;
    if (!memcmp(SampleMemory+pos,chunk,4)) return SampleMemory+pos+8;
    pos += 8 + size;
    if (size & 1) ++pos;
  }
  return NULL;
}

/*
 * Copyright (C) 1988-1991 Apple Computer, Inc.
 * All rights reserved.
 *
 * Machine-independent I/O routines for IEEE floating-point numbers.
 *
 * NaN's and infinities are converted to HUGE_VAL or HUGE, which
 * happens to be infinity on IEEE machines.  Unfortunately, it is
 * impossible to preserve NaN's in a machine-independent way.
 * Infinities are, however, preserved on IEEE machines.
 *
 * These routines have been tested on the following machines:
 *    Apple Macintosh, MPW 3.1 C compiler
 *    Apple Macintosh, THINK C compiler
 *    Silicon Graphics IRIS, MIPS compiler
 *    Cray X/MP and Y/MP
 *    Digital Equipment VAX
 *
 * Implemented by Malcolm Slaney and Ken Turkowski.
 *
 * Malcolm Slaney contributions during 1988-1990 include big- and little-
 * endian file I/O, conversion to and from Motorola's extended 80-bit
 * floating-point format, and conversions to and from IEEE single-
 * precision floating-point format.
 *
 * In 1991, Ken Turkowski implemented the conversions to and from
 * IEEE double-precision format, added more precision to the extended
 * conversions, and accommodated conversions involving +/- infinity,
 * NaN's, and denormalized numbers.
 */
#define UnsignedToFloat(u) (((double)((long)(u - 2147483647L - 1))) + 2147483648.0)
static double ReadAIFFExtended(const unsigned char *bytes)
{
  double f;
  int expon;
  unsigned long hiMant, loMant;

  expon = ((bytes[0] & 0x7F) << 8) | (bytes[1] & 0xFF);
  hiMant = ReadAIFFLong((const char *)bytes+2);
  loMant = ReadAIFFLong((const char *)bytes+6);

  if (expon == 0 && hiMant == 0 && loMant == 0)
    f = 0;
  else
  {
    if (expon == 0x7FFF) /* Infinity or NaN */
      f = -1;
    else
    {
      expon -= 16383;
      f = ldexp(UnsignedToFloat(hiMant),expon -= 31);
      f += ldexp(UnsignedToFloat(loMant),expon -= 32);
    }
  }

  if (bytes[0] & 0x80)
    return -f;
  return f;
}

