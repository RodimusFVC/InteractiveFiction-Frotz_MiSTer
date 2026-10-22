/*
 * amiga.h
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

#include <diskfont/diskfont.h>
#include <dos/dos.h>
#include <intuition/classusr.h>

struct RastPort;
struct Window;
struct Screen;
struct IOAudio;

void CheckReset(void);

/* Frotz Preferences (renamed to avoid conflict with Intuition's struct Preferences) */

struct FrotzPreferences
{
  unsigned char		Version;
  unsigned char		CustomScreen;
  unsigned long		ScreenMode;
  unsigned short	Colour;
  char			TextFontName[MAXFONTNAME];
  unsigned short	TextFontSize;
  char			FixedFontName[MAXFONTNAME];
  unsigned short	FixedFontSize;
};

struct MorePreferences
{
  char			ScreenFontName[MAXFONTNAME];
  unsigned short	ScreenFontSize;
  unsigned long		Flags;
  short			Window[4];
  unsigned short	Colours[4];
  unsigned short	LeftMargin,RightMargin;
  unsigned short	V6Style;
  unsigned short	ErrorChecking;
};

#define COLOUR_NONE		0x00
#define COLOUR_BZ_ONLY		0x01
#define COLOUR_ALL_GAMES	0x02
#define COLOUR_BZ_AND_V6	0x03

#define V6_NORMAL		0x00
#define V6_640200		0x01

#define PREFS_SAVE_WINDOW	(1<<0)
#define PREFS_JUSTIFICATION	(1<<1)
#define PREFS_CENTRE_WINDOW	(1<<2)
#define PREFS_ITALIC		(1<<3)
#define PREFS_ALLFREQ		(1<<4)
#define PREFS_NO_V6_TITLE	(1<<5)
#define PREFS_MSDOS		(1<<6)
#define PREFS_IGNORE_ERROR	(1<<7)
#define PREFS_OLD_SAVE		(1<<8) /* Reserved in existing preference files. */
#define PREFS_EXPAND_ABBREV	(1<<9)

/* Games List */

#define MAX_GAME_ENTRIES 128

struct GameNode
{
  struct Node Node;
  char Author[256];
  int Release[MAX_GAME_ENTRIES];
  int Serial[MAX_GAME_ENTRIES];
  int Checksum[MAX_GAME_ENTRIES];
};

#define PORTSIG(port) (1<<((struct MsgPort *)(port))->mp_SigBit)
#define MAX(a,b) (((a) > (b)) ? (a) : (b))
#define MIN(a,b) (((a) < (b)) ? (a) : (b))
#define OS_PATHSEP ';'

/* amiga.c prototypes */

void SafeRectFill(struct RastPort *rp,long xMin,long yMin,long xMax,long yMax,unsigned long pen);
void FlushText(void);
int GetKey(UWORD *qualifier_addr);
void DrawCursor(int under);
void ShowAbout();
int CharLength(int c);
void MoveTextRow(int offset,int max);
void CursorLeftEnd(unsigned char *buffer,int *pos);
void CursorRightEnd(unsigned char *buffer,int *pos);
int FitTextLine(unsigned char *pointer,int new);
void Quit(int code);
void StartTimer(int timeout);
void StopTimer(void);
void StoreInHistory(unsigned char *line);
int SafeCmp(const char *a,const char *b);
void PutIntoBuffer(unsigned char *buffer,unsigned char *new,int *pos,int max_size);
void RedrawLine(unsigned char *buffer,int *pos,int max_size);
int ProcessMenus(UWORD menu_number);
int Terminate(unsigned char *buffer,int pos,int c,int pen);
void HelpGuide(void);
void WaitForMsg(struct MsgPort *port);
void BusyPointer(struct Window *window,int busy);
LONG Requester(struct Window *window,UBYTE *text,UBYTE *gadgets,...);
void CloseDisplay(void);
void GetScreenRatio(struct Screen *screen);
void SaveCursorPosition();
void RestoreCursorPosition();
void SetScreenDimensions(void);
void SetColourScheme(int custom);
void LimitWindow(int limit,int x);
void GetCursorPos(int *row,int *col);
char *PathFromLock(BPTR lock);
int SafeTryOpen(const char *path,const char *ext,BPTR *handle);
void LoadGraphicsFile(void);
int ByteSwap(unsigned short n);
char *FindPicture(int pic);
ULONG GetColour32(ULONG col);
void FreePenTable(void);
struct TextFont *OpenCorrectFont(struct TextAttr *textAttr);
int SizeGadgetHeight(struct Screen *screen);
void SetZColours(void);
void SetDosColours(void);

/* amiga_list.c prototypes */

int ScanForGame(int release,char *serial,int checksum);
int CompareGames(int r1,int r2,int s1,int s2,int c1,int c2);
char *GetGameTitle(int game);
char *GetGameAuthors(int game);
char *GetGameLevel(int game);
int SerialNumber(char *serial_string);
void ReadGamesFile(void);
void WriteGamesFile(void);

/* amiga_prefs.c prototypes */

int OpenPreferences(void);
int GetPreferences(int permanent, char *prefsfile);
void GetScreenMode(void);
void GetFont(char *name,unsigned short *size,int fixed);
void SetFontNames(void);
void AddToDirList(char *entry);
void GetDirList(struct List **list,Object *listview);
void SetDirList(struct List *list,Object *listview,ULONG how);
struct Library *CheckBGUIOpen(void);
void CloseBGUI(int action);
void ClearWindow(struct Window **window_ptr,Object **object_ptr);
void ClearObject(Object **object_ptr);
int SizeX(int x);
int SizeY(int y);
void LoadPreferences(int first);
void SavePreferences(char *name);
int LoadPrefsList(BPTR file, struct List *list,int first);
void SavePrefsList(BPTR file,struct List *list);
LONG BGUIRequester(Object *window,UBYTE *text,UBYTE *gadgets,...);
struct List *CreateList(struct List **list);
void DeleteList(struct List **list,BOOL all,HOOKFUNC hook);
struct Node *CreateNode(struct List *list,char *name,int size);
void ChangeColours(void);
BPTR OpenPrefs(int first);

/* amiga_sound.c prototypes */

int InitializeSound(void);
void ResetSound(void);
void BeginSoundIO(struct IOAudio *AudioRequest);
void SetupSoundDirectory(void);
BPTR OpenSoundData(int number);
void OpenAIFF(int length);
char *FindAIFFChunk(const char *chunk, int length);

/* amiga_start.c prototypes */

void GetGameFilename(void);
int ScanSearchDirectories(void);
void ScanDirectory(BPTR dir);
int TestDirectory(BPTR lock);
void AddGameList(char *game,BPTR dir);
int RequestGame(struct Window *window);
void CreateFoundNode(int game_number,BPTR dir,char *file,char *header);
void DeleteFoundNode(struct Node *node);
int OpenStartWindow(void);
void CloseStartWindow(void);
void HandleStartWindow(void);
void RemoveDuplicateEntries(void);
void SortEntries(void);
