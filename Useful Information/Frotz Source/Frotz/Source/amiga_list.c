/*
 * amiga_list.c
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

#include <stdio.h>
#include <string.h>
#include "frotz.h"
#include "amiga.h"

int SerialNumbers[][3] =
{
 0, 77,850814,	/* A Mind Forever Voyaging */
 0, 79,851122,

 1, 54,890606,	/* Arthur */
 1, 63,890622,
 1, 74,890714,

 2, 97,851218,	/* Ballyhoo */

 3, 47,870915,	/* Beyond Zork */
 3, 49,870917,
 3, 51,870923,
 3, 57,871221,

 4,  9,871008,	/* Border Zone */

 5, 86,870212,	/* Bureaucracy */
 5,116,870602,

 6, 23,840809,	/* Cutthroats */

 7, 26,821108,	/* Deadline */
 7, 27,831005,

 8, 10,830810,	/* Enchanter */
 8, 16,831118,
 8, 24,851118,
 8, 29,860820,

 9, 47,840914,	/* The Hitchhiker's Guide to the Galaxy */
 9, 56,841221,
 9, 58,851002,
 9, 59,851108,
 9, 31,871119,

10, 37,861215,	/* Hollywood Hijinx */

11, 22,830916,	/* Infidel */

12, 26,890316,	/* Journey */
12, 30,890322,
12, 77,890616,
12, 83,890706,

13,118,860325,	/* Leather Goddesses of Phobos */
13, 50,860711,
13, 59,860730,
13,  4,880405,

14,203,870506,	/* The Lurking Horror */
14,219,870912,
14,221,870918,

15,  4,860918,	/* Moonmist */
15,  9,861022,

16, 19,870722,	/* Nord and Bert Couldn't Make Head or Tail of It */

17, 20,830708,	/* Planetfall */
17, 29,840118,
17, 37,851003,
17, 10,880531,

18, 26,870730,	/* Plundered Hearts */

19, 15,840501,	/* Seastalker */
19, 15,840522,
19, 16,850515,
19, 16,850603,

20, 21,871214,	/* Sherlock */
20, 26,880127,

21,292,890314,	/* Shogun */
21,295,890321,
21,311,890510,
21,322,890706,

22,  4,840131,	/* Sorcerer */
22,  6,840508,
22, 13,851021,
22, 15,851108,
22, 18,860904,

23, 63,850916,	/* Spellbreaker */
23, 87,860904,

24, 15,820901,	/* Starcross */
24, 17,821021,

25,107,870430,	/* Stationfall */

26, 14,841005,	/* Suspect */

27,  5,830222,	/* Suspended */
27,  7,830419,
27,  8,830521,
27,  8,840521,

28, 11,860509,	/* Trinity */
28, 12,860926,

29, 68,850501,	/* Wishbringer */
29, 69,850920,
29, 23,880706,

30, 13,830524,	/* The Witness */
30, 20,831119,
30, 21,831208,
30, 22,840924,

31, 25,820515,	/* Zork I */
31, 28,821013,
31, 30,830330,
31, 75,830929,
31, 76,840509,
31, 88,840726,
31, 52,871125,

32, 18,820517,	/* Zork II */
32, 22,830331,
32, 48,840904,

33, 10,820818,	/* Zork III */
33, 15,830331,
33, 15,840518,
33, 17,840727,

34,296,881019,	/* Zork Zero */
34,366,890323,
34,383,890602,
34,393,890714,

-1,0,0
};

char *GameInformation[][2] =
{
  "A Mind Forever Voyaging","Steve Meretzky",
  "Arthur: The Quest for Excalibur","Bob Bates",
  "Ballyhoo","Jeff O'Neill",
  "Beyond Zork: The Coconut of Quendor","Brian Moriarty",
  "Border Zone","Marc Blank",
  "Bureaucracy","Douglas Adams & Infocom",
  "Cutthroats","Michael Berlyn & Jerry Wolper",
  "Deadline","Marc Blank",
  "Enchanter","Marc Blank & Dave Lebling",
  "Hitchhiker's Guide to the Galaxy","Douglas Adams & Steve Meretzky",
  "Hollywood Hijinx","Dave Anderson & Liz Cyr-Jones",
  "Infidel","Michael Berlyn & Patricia Fogleman",
  "Journey","Marc Blank",
  "Leather Goddesses of Phobos","Steve Meretzky",
  "Lurking Horror","Dave Lebling",
  "Moonmist","Stu Galley & Jim Lawrence",
  "Nord and Bert","Jeff O'Neill",
  "Planetfall","Steve Meretzky",
  "Plundered Hearts","Amy Briggs",
  "Seastalker","Stu Galley & Jim Lawrence",
  "Sherlock: The Riddle Of The Crown Jewels","Bob Bates",
  "Shogun","Dave Lebling",
  "Sorcerer","Steve Meretzky",
  "Spellbreaker","Dave Lebling",
  "Starcross","Dave Lebling",
  "Stationfall","Steve Meretzky",
  "Suspect","Dave Lebling",
  "Suspended","Michael Berlyn",
  "Trinity","Brian Moriarty",
  "Wishbringer: The Magick Stone of Dreams","Brian Moriarty",
  "Witness","Stu Galley",
  "Zork I: The Great Underground Empire","Marc Blank & Dave Lebling",
  "Zork II: The Wizard of Frobozz","Marc Blank & Dave Lebling",
  "Zork III: The Dungeon Master","Marc Blank & Dave Lebling",
  "Zork Zero: The Revenge of Megaboz","Steve Meretzky"
};

short GameLevels[] =
{ 3,0,2,0,0,0,2,4,2,2,2,3,0,2,0,1,0,2,0,1,0,0,3,4,4,0,3,4,2,1,2,2,3,3,0 };

extern struct List *GamesList;

int ScanForGame(int release,char *serial,int checksum)
{
int game_number = -1;
int i;
struct GameNode *node;

  for(i = 0; SerialNumbers[i][0] != -1; i++)
  {
    if (CompareGames(release,SerialNumbers[i][1],SerialNumber(serial),SerialNumbers[i][2],0,0))
      game_number = SerialNumbers[i][0];
  }
  node = (struct GameNode *)GamesList->lh_Head;
  while (node->Node.ln_Succ)
  {
    i = 0;
    while ((i < MAX_GAME_ENTRIES) && (node->Serial[i] != 0))
    {
      if (CompareGames(release,node->Release[i],SerialNumber(serial),node->Serial[i],checksum,node->Checksum[i]))
	game_number = (int)node->Node.ln_Pri;
      i++;
    }
    node = (struct GameNode *)node->Node.ln_Succ;
  }
  return game_number;
}

int CompareGames(int r1,int r2,int s1,int s2,int c1,int c2)
{
  if (r1 != r2) return 0;
  if (s1 != s2) return 0;
  if ((c1 == 0) || (c2 == 0)) return 1;
  return c1 == c2 ? 1 : 0;
}

char *GetGameTitle(int game)
{
struct GameNode *node;

  if (game >= 0) return GameInformation[game][0];
  if (game < -1)
  {
    node = (struct GameNode *)GamesList->lh_Head;
    while (node->Node.ln_Succ)
    {
      if (game == (int)node->Node.ln_Pri) return node->Node.ln_Name;
      node = (struct GameNode *)node->Node.ln_Succ;
    }
  }
  return "";
}

char *GetGameAuthors(int game)
{
struct GameNode *node;

  if (game >= 0) return GameInformation[game][1];
  if (game < -1)
  {
    node = (struct GameNode *)GamesList->lh_Head;
    while (node->Node.ln_Succ)
    {
      if (game == (int)node->Node.ln_Pri) return node->Author;
      node = (struct GameNode *)node->Node.ln_Succ;
    }
  }
  return "";
}

char *GetGameLevel(int game)
{
  if (game >= 0)
  {
    switch (GameLevels[game])
    {
      case 1:
	return "Introductory Level\n\n";
      case 2:
	return "Standard Level\n\n";
      case 3:
	return "Advanced Level\n\n";
      case 4:
	return "Expert Level\n\n";
    }
  }
  return "";
}

int SerialNumber(char *serial_string)
{
int serial_number = 0;
int i;

  for (i = 0; i < 6; i++)
  {
    serial_number = serial_number*10;
    serial_number += *(serial_string+i)-'0';
  }
  return serial_number;
}

void ReadGamesFile(void)
{
static int first_time = 0;

  if (first_time == 1) return;
  first_time = 1;

  CreateList(&GamesList);

FILE *file;

  if ((file = fopen("Infocom.games","r")) == 0)
  {
    if ((file = fopen("PROGDIR:Infocom.games","r")) == 0) return;
  }

struct GameNode *node = 0;
char line[256];
char *end;
char priority = -2;
int release, serial, checksum;
int current_entry;

  while (feof(file) == 0)
  {
    *line = '\0';
    fgets(line,256,file);

    if (*line == '[')
    {
      if (end = strrchr(line,']'))
      {
	*end = '\0';
	node = (struct GameNode *)CreateNode(GamesList,line+1,sizeof(struct GameNode));
	node->Node.ln_Pri = priority;
	priority--;
	current_entry = 0;
      }
    }

    if (strncmp(line,"Author=",7) == 0)
    {
      if (node) strcpy(node->Author,line+7);
      if (end = strrchr(node->Author,'\n')) *end = '\0';
    }

    checksum = 0;
    if (sscanf(line,"%d / %d / $%X",&release,&serial,&checksum) >= 2)
    {
      if (node)
      {
	if (current_entry < MAX_GAME_ENTRIES)
	{
	  node->Release[current_entry] = release;
	  node->Serial[current_entry] = serial;
	  node->Checksum[current_entry] = checksum;
	  current_entry++;
	}
      }
    }
  }
  fclose(file);
}

void WriteGamesFile(void)
{
FILE *file;
struct GameNode *node;
int current_entry;

  if ((file = fopen("PROGDIR:Infocom.games","w")) == 0) return;

  node = (struct GameNode *)GamesList->lh_Head;
  while (node->Node.ln_Succ)
  {
    fprintf(file,"[%s]\n",node->Node.ln_Name);
    if (strcmp(node->Author,"") != 0) fprintf(file,"Author=%s\n",node->Author);
    current_entry = 0;
    while ((current_entry < MAX_GAME_ENTRIES) && (node->Serial[current_entry] != 0))
    {
      fprintf(file,"%d / %d",node->Release[current_entry],node->Serial[current_entry]);
      if (node->Checksum[current_entry] > 0)
	fprintf(file," / $%X",node->Checksum[current_entry]);
      fprintf(file,"\n");
      current_entry++;
    }
    fprintf(file,"\n");
    node = (struct GameNode *)node->Node.ln_Succ;
  }
  fclose(file);
}
