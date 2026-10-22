/*
 * amiga_start.c
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

#include <proto/asl.h>
#include <proto/dos.h>
#include <proto/exec.h>
#include <proto/gadtools.h>
#include <proto/graphics.h>
#include <proto/icon.h>
#include <proto/intuition.h>
#include <proto/wb.h>
#include <intuition/intuitionbase.h>
#include <exec/memory.h>
#include <workbench/startup.h>
#include <string.h>
#include <stdlib.h>
#include "frotz.h"
#include "amiga.h"
#include "amiga_port.h"

struct FoundNode
{
  struct Node Node;
  int Release;
  int Serial;
  char *PathName;
};

extern struct WBStartup *WBMessage;
extern struct DiskObject *SaveIcon;
extern struct List *SearchDirs;
extern struct List *ExcludeDirs;
extern struct List *GamesList;
struct List *FoundGames;
struct Screen *StartPubScreen;
struct Window *StartWindow;
struct FileRequester *GameRequester;
struct MsgPort *AppMsgPort;
struct AppWindow *AppWindow;
APTR VisualInfo;
APTR GadgetList;

char *GamePattern = "(~(#?.#?)|#?.(dat#?|z?|zlb|zblorb))";
char *SelectTitle = "Select with File Requester";
char ProcessedGamePattern[32];
char *GameFilename;

int main(int argc, char *argv[]);

int wbmain(struct WBStartup *wbmsg)
{
static char *args[2] = { "Frotz","-W" };

  WBMessage = wbmsg;
  main(2,args);
  exit(0);
}

void GetGameFilename(void)
{
  if (WBMessage)
  {
    if (WBMessage->sm_ArgList[0].wa_Lock)
      CurrentDir(WBMessage->sm_ArgList[0].wa_Lock);
    if (SaveIcon = GetDiskObject("Icon.Data"))
    {
      SaveIcon->do_CurrentX = NO_ICON_POSITION;
      SaveIcon->do_CurrentY = NO_ICON_POSITION;
    }

    if (WBMessage->sm_NumArgs > 1)
    {
      if (WBMessage->sm_ArgList[1].wa_Lock)
	CurrentDir(WBMessage->sm_ArgList[1].wa_Lock);
      GameFilename = strdup(WBMessage->sm_ArgList[1].wa_Name);
      if (!GameFilename) os_fatal("Out of memory");
      return;
    }
  }

  if (ScanSearchDirectories())
  {
    if (GameRequester) FreeAslRequest(GameRequester);
    return;
  }
  if (RequestGame(0))
  {
    if (GameRequester) FreeAslRequest(GameRequester);
    return;
  }

  DeleteList(&SearchDirs,1,0);
  DeleteList(&ExcludeDirs,1,0);
  DeleteList(&GamesList,1,0);
  exit(0);
}

int ScanSearchDirectories(void)
{
struct Node *node;
struct Process *process;
struct Window *old_process_window;
BPTR lock;
int search_return = 0;

  if (CreateList(&FoundGames) == 0) return 0;
  ReadGamesFile();

  process = (struct Process *)FindTask(0);
  old_process_window = process->pr_WindowPtr;
  process->pr_WindowPtr = (struct Window *)~0L;

  ParsePatternNoCase(GamePattern,ProcessedGamePattern,32);

  node = SearchDirs->lh_Head;
  while(node->ln_Succ)
  {
    if (lock = Lock(node->ln_Name,ACCESS_READ)) ScanDirectory(lock);
    node = node->ln_Succ;
  }

  process->pr_WindowPtr = old_process_window;

  RemoveDuplicateEntries();
  SortEntries();
  if (OpenStartWindow())
  {
    HandleStartWindow();
    search_return = 1;
  }
  CloseStartWindow();
  DeleteList(&FoundGames,1,(HOOKFUNC)DeleteFoundNode);
  return search_return;
}

void ScanDirectory(BPTR dir)
{
struct FileInfoBlock *fib;
BPTR old_dir,new_dir;

  old_dir = CurrentDir(dir);

  if ((fib = AllocDosObject(DOS_FIB,0)) == 0) { CurrentDir(old_dir); UnLock(dir); return; }
  Examine(dir,fib);

  while (ExNext(dir,fib))
  {
    if (fib->fib_DirEntryType > 0)
    {
      if (new_dir = Lock(fib->fib_FileName,ACCESS_READ))
      {
	TestDirectory(new_dir) ? ScanDirectory(new_dir) : UnLock(new_dir);
      }
    }
    else AddGameList(fib->fib_FileName,dir);
  }

  FreeDosObject(DOS_FIB,fib);
  CurrentDir(old_dir);
  UnLock(dir);
}

int TestDirectory(BPTR lock)
{
  struct Node *node;
  char *path = PathFromLock(lock);
  int result = 1;
  if (!path) return 0;
  for (node = ExcludeDirs->lh_Head; node->ln_Succ; node = node->ln_Succ) {
    if (stricmp(path,node->ln_Name) == 0) { result = 0; break; }
  }
  free(path);
  return result;
}

void AddGameList(char *game,BPTR dir)
{
BPTR file;
char *header;
int game_number = -1;

  if (MatchPatternNoCase(ProcessedGamePattern,game) == 0) return;

  if (header = AllocVec(64,MEMF_CLEAR))
  {
    if (file = Open(game,MODE_OLDFILE))
    {
      Read(file,header,64);
      Close(file);
      game_number = ScanForGame((int)(*((zword *)(header+H_RELEASE))),header+H_SERIAL,(int)(*((zword *)(header+H_CHECKSUM))));
      if (game_number != -1) CreateFoundNode(game_number,dir,game,header);
    }
    FreeVec(header);
  }
}

int RequestGame(struct Window *window)
{
int req_return;

  if (GameRequester == 0)
  {
    GameRequester = AllocAslRequestTags(ASL_FileRequest,
      ASLFR_RejectIcons,1,
      ASLFR_DoPatterns,1,
      ASLFR_SleepWindow,1,
      ASLFR_TitleText,"Select an Infocom Game",
      ASLFR_InitialPattern,GamePattern,TAG_DONE);
  }

  if (GameRequester)
  {
    req_return = AslRequestTags(GameRequester,
      ASLFR_Window,window,TAG_DONE);
    if (req_return) {
      free(GameFilename);
      GameFilename = amiga_join_path(GameRequester->fr_Drawer,GameRequester->fr_File);
      return 1;
    }
  }
  return 0;
}

void CreateFoundNode(int game_number,BPTR dir,char *file,char *header)
{
struct FoundNode *node;

  if (node = AllocVec(sizeof(struct FoundNode),MEMF_CLEAR))
  {
    node->Node.ln_Name = GetGameTitle(game_number);
    if (game_number >= 0)
      node->Node.ln_Pri = 127-game_number;
    else
      node->Node.ln_Pri = game_number;
    {
      char *path = PathFromLock(dir);
      if (!path) { FreeVec(node); return; }
      node->PathName = amiga_join_path(path,file);
      free(path);
    }
    Enqueue(FoundGames,(struct Node *)node);
    node->Release = (int)(*((zword *)(header+H_RELEASE)));
    node->Serial = SerialNumber(header+H_SERIAL);
    return;
  }
  if (node) FreeVec(node);
}

void DeleteFoundNode(struct Node *node)
{
  free(((struct FoundNode *)node)->PathName);
}

int OpenStartWindow(void)
{
extern int ScreenWidth, ScreenHeight;
extern int ScaleX, ScaleY;
int x_offset, y_offset;
int gadget_width, length;
int listview_height = 0;
int window_width;
struct Gadget *gadget;
struct Node *node;

struct NewGadget listview;
struct NewGadget button;

  node = FoundGames->lh_Head;
  if (node->ln_Succ == 0) return 0;

  if ((StartPubScreen = LockPubScreen(0)) == 0) return 0;
  GetScreenRatio(StartPubScreen);

  if ((VisualInfo = GetVisualInfo(StartPubScreen,TAG_DONE)) == 0) return 0;
  if ((gadget = CreateContext(&GadgetList)) == 0) return 0;

  x_offset = SizeX(8);
  y_offset = SizeY(4);

  gadget_width = TextLength(&(StartPubScreen->RastPort),SelectTitle,strlen(SelectTitle));
  while (node->ln_Succ)
  {
    length = TextLength(&(StartPubScreen->RastPort),node->ln_Name,strlen(node->ln_Name));
    if (length > gadget_width) gadget_width = length;

    if (listview_height < ((ScreenHeight*13)/16)-(StartPubScreen->Font->ta_YSize*4))
      listview_height += StartPubScreen->Font->ta_YSize;

    node = node->ln_Succ;
  }

  gadget_width += 24;
  window_width = gadget_width+(x_offset*2)+StartPubScreen->WBorLeft+StartPubScreen->WBorRight;
  if (window_width > ScreenWidth)
  {
    window_width = ScreenWidth;
    gadget_width = window_width-(x_offset*2)-StartPubScreen->WBorLeft-StartPubScreen->WBorRight;
  }

  if (listview_height < StartPubScreen->Font->ta_YSize*3)
    listview_height = StartPubScreen->Font->ta_YSize*3;
  listview_height += 4;

  listview.ng_LeftEdge = StartPubScreen->WBorLeft+x_offset;
  listview.ng_TopEdge = StartPubScreen->WBorTop+StartPubScreen->Font->ta_YSize+1+y_offset;
  listview.ng_Width = gadget_width;
  listview.ng_Height = listview_height;
  listview.ng_GadgetText = 0;
  listview.ng_TextAttr = StartPubScreen->Font;
  listview.ng_GadgetID = 1;
  listview.ng_Flags = 0;
  listview.ng_VisualInfo = VisualInfo;
  listview.ng_UserData = 0;
  gadget = CreateGadget(LISTVIEW_KIND,gadget,&listview,
    GTLV_Labels,FoundGames,
    GTLV_ScrollWidth,16,
    TAG_DONE);
  if (gadget == 0) return 0;

  button.ng_LeftEdge = listview.ng_LeftEdge;
  button.ng_TopEdge = listview.ng_TopEdge+listview.ng_Height+y_offset;
  button.ng_Width = gadget_width;
  button.ng_Height = StartPubScreen->Font->ta_YSize+4;
  button.ng_GadgetText = SelectTitle;
  button.ng_TextAttr = StartPubScreen->Font;
  button.ng_GadgetID = 2;
  button.ng_Flags = PLACETEXT_IN;
  button.ng_VisualInfo = VisualInfo;
  button.ng_UserData = 0;
  gadget = CreateGadget(BUTTON_KIND,gadget,&button,TAG_DONE);
  if (gadget == 0) return 0;

  StartWindow = OpenWindowTags(0,
    WA_Left,(ScreenWidth-window_width)/2,
    WA_Top,StartPubScreen->BarHeight+(StartPubScreen->Font->ta_YSize/2)+2,
    WA_Width,window_width,
    WA_Height,button.ng_TopEdge+button.ng_Height+y_offset+StartPubScreen->WBorBottom,
    WA_IDCMP,IDCMP_CLOSEWINDOW|IDCMP_GADGETUP|LISTVIEWIDCMP|BUTTONIDCMP,
    WA_Gadgets,GadgetList,
    WA_Activate,1,
    WA_RMBTrap,1,
    WA_CloseGadget,1,
    WA_DragBar,1,
    WA_DepthGadget,1,
    WA_AutoAdjust,1,
    WA_Title,"Frotz",
    WA_ScreenTitle,"Select an Infocom game to load.",
    TAG_DONE);
  if (StartWindow == 0) return 0;
  GT_RefreshWindow(StartWindow,0);

  if ((AppMsgPort = CreateMsgPort()) == 0) return 0;
  if ((AppWindow = AddAppWindowA(0,0,StartWindow,AppMsgPort,0)) == 0)
    return 0;

  return 1;
}

void CloseStartWindow(void)
{
  if (AppWindow) RemoveAppWindow(AppWindow);
  if (AppMsgPort) DeleteMsgPort(AppMsgPort);
  if (StartWindow) CloseWindow(StartWindow);
  if (GadgetList) FreeGadgets(GadgetList);
  if (VisualInfo) FreeVisualInfo(VisualInfo);
  if (StartPubScreen) UnlockPubScreen(0,StartPubScreen);
}

void HandleStartWindow(void)
{
struct IntuiMessage *imsg;
struct AppMessage *amsg;
struct FoundNode *node;
USHORT code, qualifier, apptype;
ULONG class;
APTR addr;

  while(1)
  {
    while (imsg = GT_GetIMsg(StartWindow->UserPort))
    {
      class = imsg->Class;
      code = imsg->Code;
      qualifier = imsg->Qualifier;
      addr = imsg->IAddress;
      GT_ReplyIMsg(imsg);

      switch (class)
      {
	case IDCMP_CLOSEWINDOW:
	  CloseStartWindow();
	  DeleteList(&FoundGames,1,(HOOKFUNC)DeleteFoundNode);
	  DeleteList(&SearchDirs,1,0);
	  DeleteList(&ExcludeDirs,1,0);
	  DeleteList(&GamesList,1,0);
	  if (GameRequester) FreeAslRequest(GameRequester);
	  exit(0);
	  break;
	case IDCMP_GADGETUP:
	  switch(((struct Gadget *)addr)->GadgetID)
	  {
	    case 1:
	      node = (struct FoundNode *)FoundGames->lh_Head;
	      while (code > 0)
	      {
		node = (struct FoundNode *)node->Node.ln_Succ;
		code--;
	      }
	      if (qualifier & (IEQUALIFIER_LSHIFT|IEQUALIFIER_RSHIFT))
	      {
		Requester(StartWindow,"%s\nRelease %ld / Serial no. %ld\n\n%s","Continue",
		  node->Node.ln_Name,node->Release,node->Serial,node->PathName);
	      }
	      else
	      {
		free(GameFilename);
		GameFilename = strdup(node->PathName);
		if (!GameFilename) os_fatal("Out of memory");
		return;
	      }
	      break;
	    case 2:
	      if (RequestGame(StartWindow)) return;
	      break;
	  }
	  break;
      }
    }
    while (amsg = (struct AppMessage *)GetMsg(AppMsgPort))
    {
      apptype = 0;
      if (amsg->am_Type == AMTYPE_APPWINDOW && amsg->am_NumArgs > 0) {
        char *path = amsg->am_ArgList[0].wa_Lock ?
          PathFromLock(amsg->am_ArgList[0].wa_Lock) : strdup("");
        if (path) {
          free(GameFilename);
          GameFilename = amiga_join_path(path,amsg->am_ArgList[0].wa_Name);
          free(path);
          apptype = AMTYPE_APPWINDOW;
        }
      }
      ReplyMsg((struct Message *)amsg);
      if (apptype == AMTYPE_APPWINDOW) return;
    }
    Wait(PORTSIG(StartWindow->UserPort)|PORTSIG(AppMsgPort));
  }
}

void RemoveDuplicateEntries(void)
{
struct FoundNode *current_node;
struct FoundNode *next_node;

  current_node = (struct FoundNode *)FoundGames->lh_Head;
  while (current_node->Node.ln_Succ)
  {
    next_node = (struct FoundNode *)current_node->Node.ln_Succ;
    while ((next_node->Node.ln_Succ) && (current_node->Node.ln_Pri == next_node->Node.ln_Pri))
    {
      Remove((struct Node *)next_node);
      DeleteFoundNode((struct Node *)next_node);
      FreeVec(next_node);
      next_node = (struct FoundNode *)current_node->Node.ln_Succ;
    }
    current_node = (struct FoundNode *)current_node->Node.ln_Succ;
  }
}

void SortEntries(void)
{
struct FoundNode *node;
struct FoundNode *next_node;
struct FoundNode *previous_node;
struct FoundNode *compare_node;

  node = (struct FoundNode *)FoundGames->lh_Head;
  while (node->Node.ln_Succ)
  {
    if (node->Node.ln_Pri < 0)
    {
      compare_node = (struct FoundNode *)FoundGames->lh_Head;
      while ((compare_node != node) && (strcmp(compare_node->Node.ln_Name,node->Node.ln_Name) < 0))
	compare_node = (struct FoundNode *)compare_node->Node.ln_Succ;

      previous_node = (struct FoundNode *)compare_node->Node.ln_Pred;
      next_node = (struct FoundNode *)node->Node.ln_Succ;

      Remove((struct Node *)node);
      Insert(FoundGames,(struct Node *)node,(struct Node *)previous_node);
      node = next_node;
    }
    else node = (struct FoundNode *)node->Node.ln_Succ;
  }
}
