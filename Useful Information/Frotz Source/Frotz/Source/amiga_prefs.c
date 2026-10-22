/*
 * amiga_prefs.c
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
#include <proto/bgui.h>
#include <proto/dos.h>
#include <proto/exec.h>
#include <proto/graphics.h>
#include <clib/alib_protos.h>
#include <proto/intuition.h>
/* Undefine Intuition's NewObject macro to avoid conflict with BGUI's BGUI_NewObject inline */
#ifdef NewObject
#undef NewObject
#endif
#include <proto/reqtools.h>
#include <exec/exec.h>
#include <libraries/bgui_macros.h>
#include <libraries/reqtools.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include "frotz.h"
#include "amiga.h"
#include "amiga_port.h"
#include "checkbox.h"

#define MIN_BGUI 41
#define PREFS_VERSION 2

struct Library *BGUIBase;
extern struct Library *AslBase;
extern struct Window *Window;
extern struct List *SearchDirs;
extern struct List *ExcludeDirs;
extern struct List *GamesList;
extern struct FrotzPreferences FrotzPrefs;
extern struct MorePreferences MoreFrotzPrefs;
struct FrotzPreferences TempPrefs;
struct MorePreferences MoreTempPrefs;
extern struct Screen *DefaultPubScreen;
extern struct Screen *Screen;
extern USHORT CustomColours[];
extern int UsingColour;
int ResetScreen;

struct ReqToolsBase *ReqToolsBase;
struct Window *PrefsWindow;
struct ScreenModeRequester *ScreenModeRequester;
struct FontRequester *FontRequester;
Object *PrefsObject;
Object *CustomScreen, *ScreenModeInfo, *ScreenFontInfo;
Object *TextFontInfo, *FixedFontInfo;
Object *V6Cycle, *ColourCycle, *ModeCycle, *ErrorCycle;
Object *SaveWndCheck, *CentreCheck, *ChooseColours;
Object *LeftMarginInt, *RightMarginInt, *JustifyCheck, *ItalicCheck;
Object *TitleBarCheck, *IgnoreCheck, *AbbrevCheck;
Object *SearchDirList, *SearchDirString;
Object *ExcludeDirList, *ExcludeDirString;
Object *CurrentDirList, *CurrentDirString;
Object *WhichDir, *PrefsFileReq;
Object *GamesListview, *GameName, *GameAuthor;
struct NameInfo ModeName;
char ScreenFontName[256], TextFontName[256], FixedFontName[256];

extern int init_err_report_mode;
extern int init_option_ignore_errors;
extern int init_option_expand_abbreviations;

int OpenPreferences(void)
{
  if (CheckBGUIOpen() == 0) return 0;
  if (InitCheckClass() == 0)
  {
    CloseBGUI(1);
    return 0;
  }

enum id { ID_SAVE = 1,		ID_USE,		ID_CANCEL,
	  ID_SCREENMODE,	ID_TEXTFONT,	ID_FIXEDFONT,
	  ID_WHICHDIR,		ID_DIRSTRING,	ID_DIRFILEREQ,
	  ID_DIRDELETE,		ID_GAMESLIST,	ID_ADD,
	  ID_NEWGAME,		ID_DELGAME,	ID_GAMENAME,
	  ID_SCREENFONT,	ID_RESETWINDOW,	ID_RESETMODE,
	  ID_RESETFONTS,	ID_COLOURS,	ID_RESETCOLOURS,
	  ID_RESET,		ID_SAVEAS,	ID_OPTIONS,
	  ID_OPTFREQ };

struct NewMenu menu[] = {
  Title("Preferences"),
    Item("Save As...","A",ID_SAVEAS),
    ItemBar,
    Item("Options",NULL,ID_OPTIONS),
    { NM_SUB,"Always use file requester",NULL,CHECKIT|MENUTOGGLE,0,
      (APTR)ID_OPTFREQ },
    Item("Reset",NULL,ID_RESET),
    SubItem("Window","1",ID_RESETWINDOW),
    SubItem("Screen Mode","2",ID_RESETMODE),
    SubItem("Fonts","3",ID_RESETFONTS),
    SubItem("Colours","4",ID_RESETCOLOURS),
  End };

  if (PrefsObject == 0)
  {
  static STRPTR tab_labels[] = { "Display","Options","Startup","Games",0 };
  static STRPTR col_labels[] = { "None","Beyond Zork Only","Beyond Zork & V6","All V5+ Games",0 };
  static STRPTR v6_labels[] = { "Normal","640x200",0 };
  static STRPTR mode_labels[] = { "Amiga","MS-DOS",0 };
  static STRPTR error_labels[] = { "None","Report First","Report All","Exit",0 };
  static STRPTR dir_labels[] = { "Search Directories","Exclude Directories",0 };
  static ULONG tab_map[] = { MX_Active,PAGE_Active,TAG_DONE };
  static ULONG cycle_map[] = { CYC_Active,PAGE_Active,TAG_DONE };
  Object *tabs, *pages;
  Object *mode, *screenfont, *font, *fixfont;
  Object *lists, *delsearch, *delexclude;
  Object *add, *newgame, *delgame;
  Object *save, *use, *cancel;

    PrefsObject = WindowObject,
      WINDOW_Screen,Window->WScreen,
      WINDOW_Title,"Preferences",
      WINDOW_HelpFile,"Frotz.guide",
      WINDOW_HelpNode,"prefs",
      WINDOW_MenuStrip,menu,
      WINDOW_ScaleWidth,41,
      WINDOW_CloseOnEsc,1,
      WINDOW_SmartRefresh,1,
      WINDOW_MasterGroup,
	VGroupObject,
	  HOffset(SizeX(8)),VOffset(SizeY(4)),Spacing(SizeY(2)),
	  StartMember,
	    tabs = MxObject,
	      MX_Labels,tab_labels,
	      MX_TabsObject,1,
	      MX_Active,0,
	    EndObject,
	    FixMinHeight,
	  EndMember,
	  StartMember,
	    pages = PageObject,

	      PageMember,
		VGroupObject,
		  HOffset(SizeX(8)),VOffset(SizeY(4)),Spacing(SizeY(2)),
		  VarSpace(100),
		  StartMember,
		    HGroupObject,
		      Spacing(SizeX(8)),
		      VarSpace(50),
		      StartMember,
			CustomScreen = CheckBoxObject,
			  UScoreLabel("Cus_tom Screen",'_'),
			  ButtonFrame,
			EndObject,
			FixMinSize,
		      EndMember,
		      StartMember,
			SaveWndCheck = CheckBoxObject,
			  UScoreLabel("Save _Window",'_'),
			  ButtonFrame,
			EndObject,
			FixMinSize,
		      EndMember,
		      StartMember,
			CentreCheck = CheckBoxObject,
			  UScoreLabel("C_entre Window",'_'),
			  ButtonFrame,
			EndObject,
			FixMinSize,
		      EndMember,
		      VarSpace(50),
		    EndObject,
		  EndMember,
		  StartMember,
		    HGroupObject,
		      TOffset(SizeY(2)),Spacing(SizeX(8)),
		      StartMember,
			VGroupObject,
			  Spacing(SizeY(2)),
			  StartMember,
			    HGroupObject,
			      StartMember,
				ScreenModeInfo = InfoObject,
				  UScoreLabel("Screen _Mode",'_'),
				  ButtonFrame,
				  FRM_Flags,FRF_RECESSED,
				  INFO_MinLines,1,
				  INFO_HorizOffset,SizeX(3),
				  INFO_VertOffset,SizeY(3),
				EndObject,
			      EndMember,
			      StartMember,
				mode = ButtonObject,
				  PopUp,
				  ButtonFrame,
				  GA_ID,ID_SCREENMODE,
				EndObject,
				FixMinWidth,
			      EndMember,
			    EndObject,
			  EndMember,
			  StartMember,
			    HGroupObject,
			      StartMember,
				ScreenFontInfo = InfoObject,
 				  UScoreLabel("Sc_reen Font",'_'),
				  ButtonFrame,
				  FRM_Flags,FRF_RECESSED,
				  INFO_MinLines,1,
				  INFO_HorizOffset,SizeX(3),
				  INFO_VertOffset,SizeY(3),
				EndObject,
			      EndMember,
			      StartMember,
				screenfont = ButtonObject,
				  PopUp,
				  ButtonFrame,
				  GA_ID,ID_SCREENFONT,
				EndObject,
				FixMinWidth,
			      EndMember,
			    EndObject,
			  EndMember,
			EndObject,
		      EndMember,
		      StartMember,
			VGroupObject,
			  Spacing(SizeY(2)),
			  StartMember,
			    HGroupObject,
			      StartMember,
				TextFontInfo = InfoObject,
				  UScoreLabel("Te_xt Font",'_'),
				  ButtonFrame,
				  FRM_Flags,FRF_RECESSED,
				  INFO_MinLines,1,
				  INFO_HorizOffset,SizeX(3),
				  INFO_VertOffset,SizeY(3),
				EndObject,
			      EndMember,
			      StartMember,
				font = ButtonObject,
				  PopUp,
				  ButtonFrame,
				  GA_ID,ID_TEXTFONT,
				EndObject,
				FixMinWidth,
			      EndMember,
			    EndObject,
			  EndMember,
			  StartMember,
			    HGroupObject,
			      StartMember,
				FixedFontInfo = InfoObject,
				  UScoreLabel("_Fixed Font",'_'),
				  ButtonFrame,
				  FRM_Flags,FRF_RECESSED,
				  INFO_MinLines,1,
				  INFO_HorizOffset,SizeX(3),
				  INFO_VertOffset,SizeY(3),
				EndObject,
			      EndMember,
			      StartMember,
				fixfont = ButtonObject,
				  PopUp,
				  ButtonFrame,
				  GA_ID,ID_FIXEDFONT,
				EndObject,
				FixMinWidth,
			      EndMember,
			    EndObject,
			  EndMember,
			EndObject,
		      EndMember,
		    EndObject,
		    EqualHeight,
		    FixMinHeight,
		  EndMember,
		  StartMember,
		    HGroupObject,
		      TOffset(SizeY(2)),Spacing(SizeX(8)),
		      VarSpace(50),
		      StartMember,
			JustifyCheck = CheckBoxObject,
			  UScoreLabel("Right _Justification",'_'),
			  ButtonFrame,
			EndObject,
			FixMinSize,
		      EndMember,
		      StartMember,
			ItalicCheck = CheckBoxObject,
			  UScoreLabel("_Italic",'_'),
			  ButtonFrame,
			EndObject,
			FixMinSize,
		      EndMember,
		      StartMember,
			TitleBarCheck = CheckBoxObject,
			  UScoreLabel("V6 Title _Bar",'_'),
			  ButtonFrame,
			EndObject,
			FixMinSize,
		      EndMember,
		      VarSpace(50),
		    EndObject,
		  EndMember,
		  StartMember,
		    HGroupObject,
		      TOffset(SizeY(2)),Spacing(SizeX(8)),
		      VarSpace(50),
		      StartMember,
			V6Cycle = CycleObject,
			  ButtonFrame,
			  UScoreLabel("_V6",'_'),
			  CYC_Labels,v6_labels,
			  CYC_Popup,1,
			  CYC_Active,0,
			EndObject,
		      EndMember,
		      StartMember,
			ColourCycle = CycleObject,
			  ButtonFrame,
			  UScoreLabel("C_olour",'_'),
			  CYC_Labels,col_labels,
			  CYC_Popup,1,
			  CYC_Active,0,
			EndObject,
		      EndMember,
		      StartMember,
			ChooseColours = ButtonObject,
			  UScoreLabel("C_hoose...",'_'),
			  ButtonFrame,
			  GA_ID,ID_COLOURS,
			EndObject,
		      EndMember,
		      VarSpace(50),
		    EndObject,
		    FixMinHeight,
		  EndMember,
		  VarSpace(100),
		EndObject,

	      PageMember,
		VGroupObject,
		  HOffset(SizeX(8)),VOffset(SizeY(4)),Spacing(SizeY(2)),
		  StartMember,
		    VGroupObject,
		      Spacing(SizeY(2)),EqualHeight,
		      StartMember,
			HGroupObject,
			  TOffset(SizeY(2)),Spacing(SizeX(8)),
			  VarSpace(50),
			  StartMember,
			    ModeCycle = CycleObject,
			      ButtonFrame,
			      UScoreLabel("_Mode",'_'),
			      CYC_Labels,mode_labels,
			      CYC_Popup,1,
			      CYC_Active,0,
			    EndObject,
			  EndMember,
			  StartMember,
			    ErrorCycle = CycleObject,
			      ButtonFrame,
			      UScoreLabel("_Error Checking",'_'),
			      CYC_Labels,error_labels,
			      CYC_Popup,1,
			      CYC_Active,0,
			    EndObject,
			  EndMember,
			  VarSpace(50),
			EndObject,
		      EndMember,
		      StartMember,
			HGroupObject,
			  TOffset(SizeY(2)),Spacing(SizeX(8)),
			  VarSpace(50),
			  StartMember,
			    LeftMarginInt = StringObject,
			      UScoreLabel("_Left Margin",'_'),
			      RidgeFrame,
			      STRINGA_LongVal,0,
			      STRINGA_MaxChars,5,
			      STRINGA_MinCharsVisible,5,
			      STRINGA_IntegerMin,0,
			      GA_TabCycle,1,
			    EndObject,
			    FixMinHeight,
			  EndMember,
			  StartMember,
			    RightMarginInt = StringObject,
			      UScoreLabel("_Right Margin",'_'),
			      RidgeFrame,
			      STRINGA_LongVal,0,
			      STRINGA_MaxChars,5,
			      STRINGA_MinCharsVisible,5,
			      STRINGA_IntegerMin,0,
			      GA_TabCycle,1,
			    EndObject,
			    FixMinHeight,
			  EndMember,
			  VarSpace(50),
			EndObject,
		      EndMember,
		    EndObject,
		  EndMember,

		  StartMember,
		    HGroupObject,
		      TOffset(SizeY(2)),Spacing(SizeX(8)),
		      VarSpace(50),
		      StartMember,
			VGroupObject,
			  Spacing(SizeX(2)),
			    StartMember,
			      IgnoreCheck = CheckBoxObject,
				UScoreLabel("I_gnore Runtime Errors",'_'),
				ButtonFrame,
			      EndObject,
			    FixMinSize,
			  EndMember,
			  StartMember,
			    AbbrevCheck = CheckBoxObject,
			      UScoreLabel("Expand _Abbreviations g/x/z",'_'),
			      ButtonFrame,
			    EndObject,
			    FixMinSize,
			  EndMember,
			EndObject,
		      EndMember,
		      VarSpace(50),
		    EndObject,
		  EndMember,
		  VarSpace(100),
		EndObject,

	      PageMember,
		VGroupObject,
		  HOffset(SizeX(8)),VOffset(SizeY(4)),Spacing(SizeY(2)),
		  StartMember,
		    WhichDir = CycleObject,
		      ButtonFrame,
		      CYC_Labels,dir_labels,
		      CYC_Active,0,
		      GA_ID,ID_WHICHDIR,
		    EndObject,
		    FixMinHeight,
		  EndMember,
		  StartMember,
		    lists = PageObject,

		      PageMember,
			VGroupObject,
			  StartMember,
			    SearchDirList = ListviewObject,
			      BT_DragObject,1,
			      BT_DropObject,1,
			      LISTV_ShowDropSpot,1,
			    EndObject,
			  EndMember,
			  StartMember,
			    HGroupObject,
			      EqualHeight,
			      StartMember,
				SearchDirString = StringObject,
				  RidgeFrame,
				  STRINGA_MaxChars,256,
				  GA_ID,ID_DIRSTRING,
				EndObject,
			      EndMember,
			      StartMember,
				ButtonObject,
				  GetPath,
				  ButtonFrame,
				  GA_ID,ID_DIRFILEREQ,
				EndObject,
				FixMinWidth,
			      EndMember,
			      StartMember,
				delsearch = ButtonObject,
				  UScoreLabel("_Del",'_'),
				  ButtonFrame,
				  GA_ID,ID_DIRDELETE,
				EndObject,
				FixMinWidth,
			      EndMember,
			    EndObject,
			    FixMinHeight,
			  EndMember,
			EndObject,

		      PageMember,
			VGroupObject,
			  StartMember,
			    ExcludeDirList = ListviewObject,
			      BT_DragObject,1,
			      BT_DropObject,1,
			      LISTV_ShowDropSpot,1,
			    EndObject,
			  EndMember,
			  StartMember,
			    HGroupObject,
			      EqualHeight,
			      StartMember,
				ExcludeDirString = StringObject,
				  RidgeFrame,
				  STRINGA_MaxChars,256,
				  GA_ID,ID_DIRSTRING,
				EndObject,
			      EndMember,
			      StartMember,
				ButtonObject,
				  GetPath,
				  ButtonFrame,
				  GA_ID,ID_DIRFILEREQ,
				EndObject,
				FixMinWidth,
			      EndMember,
			      StartMember,
				delexclude = ButtonObject,
				  UScoreLabel("_Del",'_'),
				  ButtonFrame,
				  GA_ID,ID_DIRDELETE,
				EndObject,
				FixMinWidth,
			      EndMember,
			    EndObject,
			    FixMinHeight,
			  EndMember,
			EndObject,

		    EndObject,
		  EndMember,
		EndObject,

	      PageMember,
		HGroupObject,
		  HOffset(SizeX(8)),VOffset(SizeY(4)),Spacing(SizeX(8)),
		  StartMember,
		    GamesListview = ListviewObject,
		      GA_ID,ID_GAMESLIST,
		    EndObject,
		  EndMember,
		  StartMember,
		    VGroupObject,
		      Spacing(SizeY(2)),
		      VarSpace(5),
		      StartMember,
			InfoObject,
			  FRM_Type,FRTYPE_NONE,
			  INFO_MinLines,1,
			  INFO_HorizOffset,SizeX(0),
			  INFO_VertOffset,SizeY(0),
			  INFO_TextFormat,"Game Name",
			EndObject,
			FixMinHeight,
		      EndMember,
		      StartMember,
			GameName = StringObject,
			  RidgeFrame,
			  STRINGA_MaxChars,256,
			  GA_ID,ID_GAMENAME,
			EndObject,
			FixMinHeight,
		      EndMember,
		      VarSpace(5),
		      StartMember,
			InfoObject,
			  FRM_Type,FRTYPE_NONE,
			  INFO_MinLines,1,
			  INFO_HorizOffset,SizeX(0),
			  INFO_VertOffset,SizeY(0),
			  INFO_TextFormat,"Game Author",
			EndObject,
			FixMinHeight,
		      EndMember,
		      StartMember,
			GameAuthor = StringObject,
			  RidgeFrame,
			  STRINGA_MaxChars,256,
			EndObject,
			FixMinHeight,
		      EndMember,
		      VarSpace(5),
		      StartMember,
			HGroupObject,
			  Spacing(SizeX(8)),
			  StartMember,
			    add = ButtonObject,
			      UScoreLabel("_Add",'_'),
			      ButtonFrame,
			      GA_ID,ID_ADD,
			    EndObject,
			  EndMember,
			  StartMember,
			    newgame = ButtonObject,
			      UScoreLabel("_New",'_'),
			      ButtonFrame,
			      GA_ID,ID_NEWGAME,
			    EndObject,
			  EndMember,
			  StartMember,
			    delgame = ButtonObject,
			      UScoreLabel("_Del",'_'),
			      ButtonFrame,
			      GA_ID,ID_DELGAME,
			    EndObject,
			  EndMember,
			EndObject,
			FixMinHeight,
		      EndMember,
		      VarSpace(25),
		    EndObject,
		  EndMember,
		EndObject,

	    EndObject,
	  EndMember,
	  StartMember,
	    HGroupObject,
	      Spacing(SizeX(8)),
	      StartMember,
		save = ButtonObject,
		  UScoreLabel("_Save",'_'),
		  ButtonFrame,
		  GA_ID,ID_SAVE,
		EndObject,
	      EndMember,
	      StartMember,
		use = ButtonObject,
		  UScoreLabel("_Use",'_'),
		  ButtonFrame,
		  GA_ID,ID_USE,
		EndObject,
	      EndMember,
              StartMember,
		cancel = ButtonObject,
		  UScoreLabel("_Cancel",'_'),
		  ButtonFrame,
		  GA_ID,ID_CANCEL,
		EndObject,
	      EndMember,
	    EndObject,
	    FixMinHeight,
	  EndMember,
	EndObject,
      EndObject;
    if (PrefsObject == 0)
    {
      CloseBGUI(1);
      return 0;
    }

    PrefsFileReq = FileReqObject,
      ASLFR_SleepWindow,1,
    EndObject;
    if (PrefsFileReq == 0)
    {
      CloseBGUI(1);
      return 0;
    }

    AddMap(tabs,pages,tab_map);
    AddMap(WhichDir,lists,cycle_map);

    GadgetKey(PrefsObject,CustomScreen,"t");
    GadgetKey(PrefsObject,SaveWndCheck,"w");
    GadgetKey(PrefsObject,CentreCheck,"e");
    GadgetKey(PrefsObject,mode,"m");
    GadgetKey(PrefsObject,screenfont,"r");
    GadgetKey(PrefsObject,font,"x");
    GadgetKey(PrefsObject,fixfont,"f");
    GadgetKey(PrefsObject,V6Cycle,"v");
    GadgetKey(PrefsObject,ColourCycle,"o");
    GadgetKey(PrefsObject,ChooseColours,"h");
    GadgetKey(PrefsObject,JustifyCheck,"j");
    GadgetKey(PrefsObject,ItalicCheck,"i");
    GadgetKey(PrefsObject,TitleBarCheck,"b");

    GadgetKey(PrefsObject,ModeCycle,"m");
    GadgetKey(PrefsObject,LeftMarginInt,"l");
    GadgetKey(PrefsObject,RightMarginInt,"r");
    GadgetKey(PrefsObject,IgnoreCheck,"g");
    GadgetKey(PrefsObject,ErrorCycle,"e");
    GadgetKey(PrefsObject,AbbrevCheck,"a");
    DoMethod(PrefsObject,WM_TABCYCLE_ORDER,
      LeftMarginInt,RightMarginInt,NULL);

    GadgetKey(PrefsObject,delsearch,"d");
    GadgetKey(PrefsObject,delexclude,"d");

    GadgetKey(PrefsObject,add,"a");
    GadgetKey(PrefsObject,newgame,"n");
    GadgetKey(PrefsObject,delgame,"d");
    DoMethod(PrefsObject,WM_TABCYCLE_ORDER,GameName,GameAuthor,NULL);

    GadgetKey(PrefsObject,save,"s");
    GadgetKey(PrefsObject,use,"u");
    GadgetKey(PrefsObject,cancel,"c");
  }

  CopyMem(&FrotzPrefs,&TempPrefs,sizeof(struct FrotzPreferences));
  CopyMem(&MoreFrotzPrefs,&MoreTempPrefs,sizeof(struct MorePreferences));

  SetAttrs(CustomScreen,GA_Selected,TempPrefs.CustomScreen,TAG_DONE);
  SetAttrs(SaveWndCheck,GA_Selected,MoreTempPrefs.Flags & PREFS_SAVE_WINDOW,
    TAG_DONE);
  SetAttrs(CentreCheck,GA_Selected,MoreTempPrefs.Flags & PREFS_CENTRE_WINDOW,
    TAG_DONE);
  GetDisplayInfoData(0,&ModeName,sizeof(struct NameInfo),DTAG_NAME,
    TempPrefs.ScreenMode);
  SetAttrs(ScreenModeInfo,INFO_TextFormat,ModeName.Name,TAG_DONE);
  SetFontNames();
  switch (MoreTempPrefs.V6Style)
  {
    case V6_NORMAL:
      SetAttrs(V6Cycle,CYC_Active,0,TAG_DONE);
      break;
    case V6_640200:
      SetAttrs(V6Cycle,CYC_Active,1,TAG_DONE);
      break;
  }
  switch (TempPrefs.Colour)
  {
    case COLOUR_NONE:
    case COLOUR_BZ_ONLY:
      SetAttrs(ColourCycle,CYC_Active,TempPrefs.Colour,TAG_DONE);
      break;
    case COLOUR_BZ_AND_V6:
      SetAttrs(ColourCycle,CYC_Active,2,TAG_DONE);
      break;
    case COLOUR_ALL_GAMES:
      SetAttrs(ColourCycle,CYC_Active,3,TAG_DONE);
      break;
  }
  SetAttrs(ChooseColours,GA_Disabled,FrotzPrefs.CustomScreen == 0 ? 1 : 0,
    TAG_DONE);
  SetAttrs(JustifyCheck,GA_Selected,
    MoreTempPrefs.Flags & PREFS_JUSTIFICATION,TAG_DONE);
  SetAttrs(ItalicCheck,GA_Selected,
    MoreTempPrefs.Flags & PREFS_ITALIC,TAG_DONE);
  SetAttrs(TitleBarCheck,GA_Selected,
    !(MoreTempPrefs.Flags & PREFS_NO_V6_TITLE),TAG_DONE);

  switch (MoreTempPrefs.ErrorChecking)
  {
    case ERR_REPORT_NEVER:
      SetAttrs(ErrorCycle,CYC_Active,0,TAG_DONE);
      break;
    case ERR_REPORT_ONCE:
      SetAttrs(ErrorCycle,CYC_Active,1,TAG_DONE);
      break;
    case ERR_REPORT_ALWAYS:
      SetAttrs(ErrorCycle,CYC_Active,2,TAG_DONE);
      break;
    case ERR_REPORT_FATAL:
      SetAttrs(ErrorCycle,CYC_Active,3,TAG_DONE);
      break;
  }
  SetAttrs(ModeCycle,CYC_Active,
    MoreTempPrefs.Flags & PREFS_MSDOS ? 1 : 0,TAG_DONE);
  SetAttrs(LeftMarginInt,STRINGA_LongVal,MoreTempPrefs.LeftMargin,
    TAG_DONE);
  SetAttrs(RightMarginInt,STRINGA_LongVal,MoreTempPrefs.RightMargin,
    TAG_DONE);
  SetAttrs(IgnoreCheck,GA_Selected,
    MoreTempPrefs.Flags & PREFS_IGNORE_ERROR,TAG_DONE);
  SetAttrs(AbbrevCheck,GA_Selected,
    MoreTempPrefs.Flags & PREFS_EXPAND_ABBREV,TAG_DONE);

  SetDirList(SearchDirs,SearchDirList,LVAP_TAIL);
  SetDirList(ExcludeDirs,ExcludeDirList,LVAP_TAIL);
  CurrentDirList = SearchDirList;
  CurrentDirString = SearchDirString;

  SetDirList(GamesList,GamesListview,LVAP_SORTED);

  SetColourScheme(0);
  if ((PrefsWindow = WindowOpen(PrefsObject)) == 0)
  {
    CloseBGUI(1);
    return 0;
  }
  if (Screen == 0) OffMenu(PrefsWindow,FULLMENUNUM(0,3,3));
  if (MoreTempPrefs.Flags & PREFS_ALLFREQ)
  {
    ItemAddress(PrefsWindow->MenuStrip,FULLMENUNUM(0,2,0))->Flags |=
      CHECKED;
  }
  else
  {
    ItemAddress(PrefsWindow->MenuStrip,FULLMENUNUM(0,2,0))->Flags &=
      ~CHECKED;
  }
  SetAttrs(PrefsFileReq,ASLFR_Window,PrefsWindow,TAG_DONE);
  BusyPointer(Window,1);

ULONG signal,code,attr;
char *entry;
struct GameNode *node;

  GetAttr(WINDOW_SigMask,PrefsObject,&signal);
  while (1)
  {
    while ((code = HandleEvent(PrefsObject)) != WMHI_NOMORE)
    {
      switch (code)
      {
	case WMHI_CLOSEWINDOW:
	case ID_CANCEL:
	  CloseBGUI(0);
	  return 0;
	  break;
	case ID_USE:
	  if (GetPreferences(0,NULL))
	  {
	    CloseBGUI(0);
	    ResetScreen = 1;
	    return 1;
	  }
	  break;
	case ID_SAVE:
	  if (GetPreferences(1,NULL))
	  {
	    CloseBGUI(0);
	    ResetScreen = 1;
	    return 1;
	  }
	  break;

	case ID_SCREENMODE:
	  GetScreenMode();
	  break;
	case ID_SCREENFONT:
	  GetFont(MoreTempPrefs.ScreenFontName,&MoreTempPrefs.ScreenFontSize,0);
	  break;
	case ID_TEXTFONT:
	  GetFont(TempPrefs.TextFontName,&TempPrefs.TextFontSize,0);
	  break;
	case ID_FIXEDFONT:
	  GetFont(TempPrefs.FixedFontName,&TempPrefs.FixedFontSize,1);
	  break;
	case ID_COLOURS:
	  ChangeColours();
	  break;

	case ID_WHICHDIR:
	  GetAttr(CYC_Active,WhichDir,&attr);
	  CurrentDirList = attr == 0 ? SearchDirList : ExcludeDirList;
	  CurrentDirString = attr == 0 ? SearchDirString : ExcludeDirString;
	  break;
	case ID_DIRSTRING:
	  GetAttr(STRINGA_TextVal,CurrentDirString,&attr);
	  AddToDirList((char *)attr);
	  break;
	case ID_DIRFILEREQ:
	  SetAttrs(PrefsFileReq,
	    ASLFR_DrawersOnly,1,
	    ASLFR_DoSaveMode,0,
	    ASLFR_TitleText,"Choose Directory",TAG_DONE);
	  if (DoRequest(PrefsFileReq) == FRQ_OK)
	  {
	    GetAttr(FRQ_Drawer,PrefsFileReq,&attr);
	    AddToDirList((char *)attr);
	  }
	  break;
	case ID_DIRDELETE:
	  entry = (char *)FirstSelected(CurrentDirList);
	  if (entry) RemoveEntryVisible(PrefsWindow,CurrentDirList,entry);
	  break;

	case ID_GAMESLIST:
	  entry = (char *)FirstSelected(GamesListview);
	  if (entry)
	  {
	    node = (struct GameNode *)GamesList->lh_Head;
	    while (node->Node.ln_Succ)
	    {
	      if (strcmp(node->Node.ln_Name,entry) == 0)
	      {
		SetGadgetAttrs((struct Gadget *)GameName,PrefsWindow,0,
		  STRINGA_TextVal,node->Node.ln_Name,TAG_DONE);
		SetGadgetAttrs((struct Gadget *)GameAuthor,PrefsWindow,0,
		  STRINGA_TextVal,node->Author,TAG_DONE);
	      }
	      node = (struct GameNode *)node->Node.ln_Succ;
	    }
	  }
	  break;
	case ID_GAMENAME:
	  ActivateGadget((struct Gadget *)GameAuthor,PrefsWindow,0);
	  break;
	case ID_ADD:
	  entry = (char *)FirstSelected(GamesListview);
	  if (entry)
	  {
	    node = (struct GameNode *)GamesList->lh_Head;
	    while (node->Node.ln_Succ)
	    {
	      if (strcmp(node->Node.ln_Name,entry) == 0)
	      {
	      int i = 0;

		while ((i < MAX_GAME_ENTRIES) && (node->Serial[i] != 0)) i++;
		if (i < MAX_GAME_ENTRIES)
		{
		  node->Release[i] = z_header.release;
		  node->Serial[i] = SerialNumber(z_header.serial);
		  node->Checksum[i] = z_header.checksum;
		  WriteGamesFile();
		  BGUIRequester(PrefsObject,"Current game added to \"%s\" list.","Continue",node->Node.ln_Name);
		}
	      }
	      node = (struct GameNode *)node->Node.ln_Succ;
	    }
	  }
	  else BGUIRequester(PrefsObject,"No game specified.","Cancel");
	  break;
	case ID_NEWGAME:
	  GetAttr(STRINGA_TextVal,GameName,&attr);
	  if (strcmp((char *)attr,"") != 0)
	  {
	    node = (struct GameNode *)
	      CreateNode(GamesList,(char *)attr,sizeof(struct GameNode));
	    if (node)
	    {
	      GetAttr(STRINGA_TextVal,GameAuthor,&attr);
	      strcpy(node->Author,(char *)attr);
	      AddEntrySelect(PrefsWindow,GamesListview,node->Node.ln_Name,LVAP_SORTED);
	      WriteGamesFile();
	    }
	  }
	  else BGUIRequester(PrefsObject,"No game name specified.","Cancel");
	  break;
	case ID_DELGAME:
	  entry = (char *)FirstSelected(GamesListview);
	  if (entry)
	  {
	    node = (struct GameNode *)GamesList->lh_Head;
	    while (node->Node.ln_Succ)
	    {
	      if (strcmp(node->Node.ln_Name,entry) == 0)
	      {
	      struct GameNode *delete_node;

		delete_node = node;
		node = (struct GameNode *)node->Node.ln_Succ;
		Remove((struct Node *)delete_node);
		FreeVec(delete_node->Node.ln_Name);
		FreeVec(delete_node);
	      }
	      else node = (struct GameNode *)node->Node.ln_Succ;
	    }
	    RemoveEntryVisible(PrefsWindow,GamesListview,entry);
	    WriteGamesFile();
	  }
	  break;

	case ID_SAVEAS:
	  SetAttrs(PrefsFileReq,
	    ASLFR_DrawersOnly,0,
	    ASLFR_DoSaveMode,1,
	    ASLFR_TitleText,"Save Preferences",TAG_DONE);
	  if (DoRequest(PrefsFileReq) == FRQ_OK)
	  {
	  char *path;

	    GetAttr(FRQ_Path,PrefsFileReq,(ULONG *)&path);
	    if (GetPreferences(1,path))
	    {
	      CloseBGUI(0);
	      ResetScreen = 1;
	      return 1;
	    }
	  }
	  break;
	case ID_RESETWINDOW:
	  MoreTempPrefs.Window[0] = 0;
	  MoreTempPrefs.Window[1] = 0;
	  MoreTempPrefs.Window[2] = 0;
	  MoreTempPrefs.Window[3] = 0;
	  break;
	case ID_RESETMODE:
	  TempPrefs.ScreenMode = GetVPModeID(&DefaultPubScreen->ViewPort);
	  GetDisplayInfoData(0,&ModeName,sizeof(struct NameInfo),
	    DTAG_NAME,TempPrefs.ScreenMode);
	  SetGadgetAttrs((struct Gadget *)ScreenModeInfo,PrefsWindow,0,
	    INFO_TextFormat,ModeName.Name,TAG_DONE);
	  break;
	case ID_RESETFONTS:
	  strcpy(TempPrefs.TextFontName,"topaz.font");
	  TempPrefs.TextFontSize = 8;
	  strcpy(TempPrefs.FixedFontName,"topaz.font");
	  TempPrefs.FixedFontSize = 8;
	  strcpy(MoreTempPrefs.ScreenFontName,"topaz.font");
	  MoreTempPrefs.ScreenFontSize = 8;
	  SetFontNames();
	  break;
	case ID_RESETCOLOURS:
	  if (Screen)
	  {
	    MoreTempPrefs.Colours[0] = 0xFFFF;
	    CustomColours[0] =
	      GetRGB4(DefaultPubScreen->ViewPort.ColorMap,0);
	    CustomColours[1] =
	      GetRGB4(DefaultPubScreen->ViewPort.ColorMap,1);
	    CustomColours[2] =
	      GetRGB4(DefaultPubScreen->ViewPort.ColorMap,2);
	    CustomColours[3] =
	      GetRGB4(DefaultPubScreen->ViewPort.ColorMap,3);
	    CopyMem(CustomColours,CustomColours+12,4*sizeof(USHORT));
	    LoadRGB4(&Screen->ViewPort,CustomColours,
	      UsingColour ? 16 : 4);
	  }
	  break;
      }
    }
    Wait(signal);
  }
}

int GetPreferences(int permanent, char *prefsfile)
{
unsigned long result;

  GetAttr(GA_Selected,CustomScreen,&result);
  TempPrefs.CustomScreen = result ? 1 : 0;
  GetAttr(GA_Selected,SaveWndCheck,&result);
  if (result)
    MoreTempPrefs.Flags |= PREFS_SAVE_WINDOW;
  else
    MoreTempPrefs.Flags &= ~PREFS_SAVE_WINDOW;
  GetAttr(GA_Selected,CentreCheck,&result);
  if (result)
    MoreTempPrefs.Flags |= PREFS_CENTRE_WINDOW;
  else
    MoreTempPrefs.Flags &= ~PREFS_CENTRE_WINDOW;
  GetAttr(CYC_Active,V6Cycle,&result);
  MoreTempPrefs.V6Style = result;
  GetAttr(CYC_Active,ColourCycle,&result);
  switch (result)
  {
    case 0:
    case 1:
      TempPrefs.Colour = result;
      break;
    case 2:
      TempPrefs.Colour = COLOUR_BZ_AND_V6;
      break;
    case 3:
      TempPrefs.Colour = COLOUR_ALL_GAMES;
      break;
  }
  GetAttr(GA_Selected,JustifyCheck,&result);
  if (result)
    MoreTempPrefs.Flags |= PREFS_JUSTIFICATION;
  else
    MoreTempPrefs.Flags &= ~PREFS_JUSTIFICATION;
  GetAttr(GA_Selected,ItalicCheck,&result);
  if (result)
    MoreTempPrefs.Flags |= PREFS_ITALIC;
  else
    MoreTempPrefs.Flags &= ~PREFS_ITALIC;
  GetAttr(GA_Selected,TitleBarCheck,&result);
  if (result)
    MoreTempPrefs.Flags &= ~PREFS_NO_V6_TITLE;
  else
    MoreTempPrefs.Flags |= PREFS_NO_V6_TITLE;

  GetAttr(CYC_Active,ErrorCycle,&result);
  MoreTempPrefs.ErrorChecking = result;
  GetAttr(CYC_Active,ModeCycle,&result);
  switch (result)
  {
    case 0:
      MoreTempPrefs.Flags &= ~PREFS_MSDOS;
      break;
    case 1:
      MoreTempPrefs.Flags |= PREFS_MSDOS;
      break;
  }
  GetAttr(STRINGA_LongVal,LeftMarginInt,&result);
  MoreTempPrefs.LeftMargin = ((signed long)result >= 0) ? result : 0;
  GetAttr(STRINGA_LongVal,RightMarginInt,&result);
  MoreTempPrefs.RightMargin = ((signed long)result >= 0) ? result : 0;
  GetAttr(GA_Selected,IgnoreCheck,&result);
  if (result)
    MoreTempPrefs.Flags |= PREFS_IGNORE_ERROR;
  else
    MoreTempPrefs.Flags &= ~PREFS_IGNORE_ERROR;
  MoreTempPrefs.Flags &= ~PREFS_OLD_SAVE; /* Reserved legacy bit. */
  GetAttr(GA_Selected,AbbrevCheck,&result);
  if (result)
    MoreTempPrefs.Flags |= PREFS_EXPAND_ABBREV;
  else
    MoreTempPrefs.Flags &= ~PREFS_EXPAND_ABBREV;

  if (ItemAddress(PrefsWindow->MenuStrip,FULLMENUNUM(0,2,0))->Flags&CHECKED)
    MoreTempPrefs.Flags |= PREFS_ALLFREQ;
  else
    MoreTempPrefs.Flags &= ~PREFS_ALLFREQ;

  GetDirList(&SearchDirs,SearchDirList);
  GetDirList(&ExcludeDirs,ExcludeDirList);

  if (TempPrefs.TextFontSize != TempPrefs.FixedFontSize)
  {
    BGUIRequester(PrefsObject,"The two fonts must have the same height.",
      "Cancel");
    return 0;
  }
  CopyMem(&TempPrefs,&FrotzPrefs,sizeof(struct FrotzPreferences));
  CopyMem(&MoreTempPrefs,&MoreFrotzPrefs,sizeof(struct MorePreferences));

  if ((Screen == 0) && (MoreFrotzPrefs.Flags & PREFS_SAVE_WINDOW))
  {
    MoreFrotzPrefs.Window[0] = Window->LeftEdge;
    MoreFrotzPrefs.Window[1] = Window->TopEdge;
    MoreFrotzPrefs.Window[2] = Window->Width;
    MoreFrotzPrefs.Window[3] = Window->Height;
  }

  FrotzPrefs.Version = PREFS_VERSION;
  if (prefsfile)
  {
    SavePreferences(prefsfile);
  }
  else
  {
    SavePreferences("ENV:Frotz.prefs");
    if (permanent) SavePreferences("ENVARC:Frotz.prefs");
  }
  return 1;
}

void GetScreenMode(void)
{
  if (AslBase->lib_Version < 38)
  {
    BGUIRequester(PrefsObject,"Need asl.library v38 or higher.","Cancel");
    return;
  }

  if (ScreenModeRequester == 0)
    ScreenModeRequester = AllocAslRequestTags(ASL_ScreenModeRequest,TAG_DONE);

  if (ScreenModeRequester)
  {
    if (AslRequestTags(ScreenModeRequester,
      ASLSM_Window,PrefsWindow,
      ASLSM_InitialHeight,PrefsWindow->WScreen->Height,
      ASLSM_InitialDisplayID,TempPrefs.ScreenMode,
      ASLSM_SleepWindow,1,TAG_DONE))
    {
      TempPrefs.ScreenMode = ScreenModeRequester->sm_DisplayID;
      GetDisplayInfoData(0,&ModeName,sizeof(struct NameInfo),
	DTAG_NAME,TempPrefs.ScreenMode);
      SetGadgetAttrs((struct Gadget *)ScreenModeInfo,PrefsWindow,0,
	INFO_TextFormat,ModeName.Name,TAG_DONE);
    }
  }
}

void GetFont(char *name,unsigned short *size,int fixed)
{
  if (FontRequester == 0)
    FontRequester = AllocAslRequestTags(ASL_FontRequest,
      ASLFO_MaxHeight,1000,TAG_DONE);

  if (FontRequester)
  {
    if (AslRequestTags(FontRequester,
      ASLFO_Window,PrefsWindow,
      ASLFO_InitialHeight,PrefsWindow->WScreen->Height,
      ASLFO_InitialName,name,
      ASLFO_InitialSize,*size,
      ASLFO_FixedWidthOnly,fixed,
      ASLFO_SleepWindow,1,TAG_DONE))
    {
      strcpy(name,FontRequester->fo_Attr.ta_Name);
      *size = FontRequester->fo_Attr.ta_YSize;
      SetFontNames();
    }
  }
}

void SetFontNames(void)
{
char *font_extension;

  strcpy(ScreenFontName,MoreTempPrefs.ScreenFontName);
  if (font_extension = strstr(ScreenFontName,".font")) *font_extension = 0;
  sprintf(ScreenFontName+strlen(ScreenFontName),"/%d",
    (int)MoreTempPrefs.ScreenFontSize);
  strcpy(TextFontName,TempPrefs.TextFontName);
  if (font_extension = strstr(TextFontName,".font")) *font_extension = 0;
  sprintf(TextFontName+strlen(TextFontName),"/%d",
    (int)TempPrefs.TextFontSize);
  strcpy(FixedFontName,TempPrefs.FixedFontName);
  if (font_extension = strstr(FixedFontName,".font")) *font_extension = 0;
  sprintf(FixedFontName+strlen(FixedFontName),"/%d",
    (int)TempPrefs.FixedFontSize);

  if (PrefsWindow)
  {
    SetGadgetAttrs((struct Gadget *)ScreenFontInfo,PrefsWindow,0,
      INFO_TextFormat,ScreenFontName,TAG_DONE);
    SetGadgetAttrs((struct Gadget *)TextFontInfo,PrefsWindow,0,
      INFO_TextFormat,TextFontName,TAG_DONE);
    SetGadgetAttrs((struct Gadget *)FixedFontInfo,PrefsWindow,0,
      INFO_TextFormat,FixedFontName,TAG_DONE);
  }
  else
  {
    SetAttrs(ScreenFontInfo,INFO_TextFormat,ScreenFontName,TAG_DONE);
    SetAttrs(TextFontInfo,INFO_TextFormat,TextFontName,TAG_DONE);
    SetAttrs(FixedFontInfo,INFO_TextFormat,FixedFontName,TAG_DONE);
  }
}

void AddToDirList(char *entry)
{
  AddEntry(PrefsWindow,CurrentDirList,entry,LVAP_TAIL);
}

void GetDirList(struct List **list,Object *listview)
{
char *entry;

  DeleteList(list,0,0);
  entry = (char *)FirstEntry(listview);
  while (entry)
  {
    CreateNode(*list,entry,sizeof(struct Node));
    entry = (char *)NextEntry(listview,entry);
  }
}

void SetDirList(struct List *list,Object *listview,ULONG how)
{
struct Node *node;

  ClearList(PrefsWindow,listview);
  node = list->lh_Head;
  while (node->ln_Succ)
  {
    AddEntry(PrefsWindow,listview,node->ln_Name,how);
    node = node->ln_Succ;
  }
}

struct Library *CheckBGUIOpen(void)
{
  if (BGUIBase == 0) BGUIBase = OpenLibrary("PROGDIR:libs/bgui.library",MIN_BGUI);
  if (BGUIBase == 0) BGUIBase = OpenLibrary("bgui.library",MIN_BGUI);
  if (BGUIBase == 0) Requester(Window,"Need bgui.library v%ld or higher.","Cancel",MIN_BGUI);
  return BGUIBase;
}

void CloseBGUI(int action)
{
  BusyPointer(Window,0);
  ClearWindow(&PrefsWindow,&PrefsObject);
  SetColourScheme(1);
  if (action >= 1)
  {
    ClearObject(&PrefsObject);
    ClearObject(&PrefsFileReq);
    if (ScreenModeRequester) FreeAslRequest(ScreenModeRequester);
    ScreenModeRequester = 0;
    if (FontRequester) FreeAslRequest(FontRequester);
    FontRequester = 0;
  }
  if (action >= 2)
  {
    FreeCheckClass();
    if (BGUIBase) CloseLibrary(BGUIBase);
    BGUIBase = 0;
  }
}

void ClearWindow(struct Window **window_ptr,Object **object_ptr)
{
  if (*window_ptr)
  {
    WindowClose(*object_ptr);
    *window_ptr = 0;
  }
}

void ClearObject(Object **object_ptr)
{
  if (*object_ptr)
  {
    DisposeObject(*object_ptr);
    *object_ptr = 0;
  }
}

int SizeX(int x)
{
extern int ScaleX;

  return ((x*ScaleX)/1000);
}

int SizeY(int y)
{
extern int ScaleY;

  return ((y*ScaleY)/1000);
}

void SetOptions(void)
{
  f_setup.err_report_mode = MoreFrotzPrefs.ErrorChecking;
  f_setup.ignore_errors = (MoreFrotzPrefs.Flags & PREFS_IGNORE_ERROR)
    ? 1 : 0;
  f_setup.expand_abbreviations = (MoreFrotzPrefs.Flags & PREFS_EXPAND_ABBREV)
    ? 1 : 0;
}

void LoadPreferences(int first)
{
BPTR file;

  FrotzPrefs.CustomScreen = 1;
  if ((DefaultPubScreen = LockPubScreen(0)) == 0) Quit(1);
  FrotzPrefs.ScreenMode = GetVPModeID(&DefaultPubScreen->ViewPort);
  UnlockPubScreen(0,DefaultPubScreen);
  DefaultPubScreen = 0;
  FrotzPrefs.Colour = COLOUR_NONE;
  strcpy(FrotzPrefs.TextFontName,"topaz.font");
  FrotzPrefs.TextFontSize = 8;
  strcpy(FrotzPrefs.FixedFontName,"topaz.font");
  FrotzPrefs.FixedFontSize = 8;
  MoreFrotzPrefs.V6Style = V6_NORMAL;

  MoreFrotzPrefs.ErrorChecking = f_setup.err_report_mode;
  if (f_setup.ignore_errors != 0)
    MoreFrotzPrefs.Flags |= PREFS_IGNORE_ERROR;
  if (f_setup.expand_abbreviations != 0)
    MoreFrotzPrefs.Flags |= PREFS_EXPAND_ABBREV;

  if (first)
  {
    CreateList(&SearchDirs);
    CreateList(&ExcludeDirs);
  }

  strcpy(MoreFrotzPrefs.ScreenFontName,FrotzPrefs.TextFontName);
  MoreFrotzPrefs.ScreenFontSize = FrotzPrefs.TextFontSize;
  MoreFrotzPrefs.Colours[0] = 0xFFFF;
  if ((file = OpenPrefs(first))) {
    struct FrotzPreferences loaded;
    struct MorePreferences more;
    if (Read(file,&loaded,sizeof(loaded)) == sizeof(loaded)) {
      loaded.TextFontName[sizeof(loaded.TextFontName)-1] = 0;
      loaded.FixedFontName[sizeof(loaded.FixedFontName)-1] = 0;
      FrotzPrefs = loaded;
      strcpy(MoreFrotzPrefs.ScreenFontName,FrotzPrefs.TextFontName);
      MoreFrotzPrefs.ScreenFontSize = FrotzPrefs.TextFontSize;
      if (LoadPrefsList(file,SearchDirs,first) &&
          LoadPrefsList(file,ExcludeDirs,first) && loaded.Version >= 2 &&
          Read(file,&more,sizeof(more)) == sizeof(more)) {
        more.ScreenFontName[sizeof(more.ScreenFontName)-1] = 0;
        MoreFrotzPrefs = more;
      }
    }
    Close(file);
  }
  MoreFrotzPrefs.Flags &= ~PREFS_OLD_SAVE;

  if (init_err_report_mode != -1)
    MoreFrotzPrefs.ErrorChecking = init_err_report_mode;

  if (init_option_ignore_errors != -1)
  {
    if (init_option_ignore_errors != 0)
      MoreFrotzPrefs.Flags |= PREFS_IGNORE_ERROR;
    else
      MoreFrotzPrefs.Flags &= ~PREFS_IGNORE_ERROR;
  }


  if (init_option_expand_abbreviations != -1)
  {
    if (init_option_expand_abbreviations != 0)
      MoreFrotzPrefs.Flags |= PREFS_EXPAND_ABBREV;
    else
      MoreFrotzPrefs.Flags &= ~PREFS_EXPAND_ABBREV;
  }

  SetOptions();
}

void SavePreferences(char *name)
{
BPTR file;

  if (file = Open(name,MODE_NEWFILE))
  {
    Write(file,&FrotzPrefs,sizeof(struct FrotzPreferences));
    SavePrefsList(file,SearchDirs);
    SavePrefsList(file,ExcludeDirs);
    Write(file,&MoreFrotzPrefs,sizeof(struct MorePreferences));
    Close(file);
  }
}

int LoadPrefsList(BPTR file, struct List *list, int first)
{
  char entry[256];
  size_t length = 0;
  for (;;) {
    char c;
    if (Read(file,&c,1) != 1) return 0;
    if (c == 0) {
      if (length == 0) return 1;
      entry[length] = 0;
      if (first && !CreateNode(list,entry,sizeof(struct Node))) return 0;
      length = 0;
    } else {
      if (length == sizeof(entry)-1) return 0;
      entry[length++] = c;
    }
  }
}

void SavePrefsList(BPTR file,struct List *list)
{
struct Node *node;

  node = list->lh_Head;
  while (node->ln_Succ)
  {
    Write(file,node->ln_Name,strlen(node->ln_Name)+1);
    node = node->ln_Succ;
  }
  Write(file,"",1);
}

void CheckReset(void)
{
  if (ResetScreen)
  {
    ResetScreen = 0;
    CloseDisplay();
    SetOptions();
    os_init_screen();
  }
}

LONG BGUIRequester(Object *window_object,UBYTE *text,UBYTE *gadgets,...)
{
va_list arguments;
LONG return_value;
struct Window *window;
static struct EasyStruct requester =
  { sizeof(struct EasyStruct),0,"Frotz",0,0 };

  requester.es_TextFormat = text;
  requester.es_GadgetFormat = gadgets;
  va_start(arguments,gadgets);
  WindowBusy(window_object);
  GetAttr(WINDOW_Window,window_object,(ULONG *)&window);
  return_value = EasyRequestArgs(window,&requester,0,arguments);
  WindowReady(window_object);
  va_end(arguments);
  return return_value;
}

struct List *CreateList(struct List **list)
{
  if (*list = AllocVec(sizeof(struct List),MEMF_CLEAR))
  {
    NewList(*list);
    return(*list);
  }
  else return(0);
}

void DeleteList(struct List **list,BOOL all,HOOKFUNC hook)
{
struct Node *node;

  if (*list != 0)
  {
    while (node = RemHead(*list))
    {
      if (hook)
      {
	hook(node);
      }
      else
      {
	FreeVec(node->ln_Name);
      }
      FreeVec(node);
    }
    if (all)
    {
      FreeVec(*list);
      *list = 0;
    }
  }
}

struct Node *CreateNode(struct List *list,char *name,int size)
{
struct Node *node;

  if (node = AllocVec(size,MEMF_CLEAR))
  {
    if (node->ln_Name = AllocVec(strlen(name)+1,MEMF_CLEAR))
    {
      strcpy(node->ln_Name,name);
      AddTail(list,node);
      return node;
    }
  }
  if (node) FreeVec(node);
  return 0;
}

void ChangeColours(void)
{
  if (ReqToolsBase = (struct ReqToolsBase *)
    OpenLibrary("reqtools.library",38))
  {
    if (rtPaletteRequest("Frotz Palette",0,
      RT_Window,PrefsWindow,
      RT_LockWindow,1,
      RT_ReqPos,REQPOS_CENTERSCR,TAG_DONE) != -1)
    {
    int i;

      for(i = 0; i < 4; i++) MoreTempPrefs.Colours[i] =
	GetRGB4(ViewPortAddress(PrefsWindow)->ColorMap,i);
    }
    CloseLibrary((struct Library *)ReqToolsBase);
    ReqToolsBase = 0;
  }
  else BGUIRequester(PrefsObject,"Need reqtools.library v38 or higher.",
    "Cancel");
}

BPTR OpenPrefs(int first)
{
  BPTR file;
  if (!first) {
    char *path = amiga_with_extension(f_setup.story_name,".prefs");
    file = Open(path,MODE_OLDFILE);
    free(path);
    if (file) return file;
    path = strdup(f_setup.story_name);
    if (!path) os_fatal("Out of memory");
    *amiga_file_part(path) = 0;
    {
      char *local = amiga_join_path(path,"Frotz.prefs");
      free(path);
      file = Open(local,MODE_OLDFILE);
      free(local);
    }
    if (file) return file;
  }
  if ((file = Open("PROGDIR:Frotz.prefs",MODE_OLDFILE))) return file;
  return Open("ENV:Frotz.prefs",MODE_OLDFILE);
}
