'==============================================================================
' Personal TRNG Firmware ver:1.19
' An open-source product with Audit-Only License.
' Published on github: mixoftix/personal_trng_firmware
' by shahiN Noursalehi
'==============================================================================

'==============================================================================
' MCU CONFIGURATION
'==============================================================================
$regfile = "m328pdef.dat"
$crystal = 8000000

' Reallocated memory profiles to isolate text buffers and nested math layers
$hwstack = 128      ' Leaves ample room for nested function return addresses
$swstack = 256      ' INCREASED: Prevents overflow from deeply nested Single function parameters
$framesize = 256    ' INCREASED: Safely covers Local String*16 buffers and Str()/Val() workspace


'==============================================================================
' UART SERIAL CONFIGURATION (Default Hardware TX on PD.1)
'==============================================================================
$baud = 115200

'==============================================================================
' SERIAL RECEIVE INTERRUPT SETUP
'==============================================================================
Enable Urxc                ' Enable UART Receive Complete Interrupt
On Urxc Isr_Serial_Rx        ' Point to the receive handler subroutine

' Global variable to store the incoming raw character or decoded hex nibble
Dim Incoming_Char As Byte

'==============================================================================
' INT0 + INT1 --> 2 dedicated independent ISRs.
'==============================================================================
Config Int0 = Rising
Disable Int0
On Int0 Isr_Int0

Config Int1 = Rising
Disable Int1
On Int1 Isr_Int1

' Global variable to store timing jitters
Dim Now_J2 As Word
Dim Last_J2 As Word
Dim Delta_J2 As Word
'Dim Block_J2(32) As Byte        ' 32-byte raw block
Dim Block_J2(32) As Word
Dim Block_J2_Index As Byte      ' 1..32

Dim Now_J3 As Word
Dim Last_J3 As Word
Dim Delta_J3 As Word
'Dim Block_J3(32) As Byte        ' 32-byte raw block
Dim Block_J3(32) As Word
Dim Block_J3_Index As Byte      ' 1..32

'==============================================================================
' SYSTEM TIMER SETUP (1 ms Heartbeat)
'==============================================================================
Config Timer0 = Timer , Prescale = 64
Timer0 = 131
Enable Timer0
On Timer0 Ticktok

'==============================================================================
' JITTER TIMER SETUP (125 ns Harvester)
'==============================================================================
Config Timer1 = Timer , Prescale = 1
Timer1 = 0
Enable Timer1

' Enable global interrupts
Enable Interrupts

'==============================================================================
' PINOUT HARDWARE CONFIGURATION
'==============================================================================
Config PortB = Output  ' Manage 7-Segment Patterns
Config PORTC = Input   ' Switches and TRNG Crystals
Config PortD = Input   ' Unused / Safety Pull-ups

' Set all output portb (High) / inverted for common anode 7-segment layout
PortB = &B11111111
' Enable internal pull-up resistors / ready to read external low states safely
PortC = &B11111111
PortD = &B11111111

'==============================================================================
' PINOUT ALIASES & HARDWARE ASSIGNMENTS
'==============================================================================
Flag_7seg_dp     Alias PortB.0
Flag_7seg_a      Alias PortB.1
Flag_7seg_b      Alias PortB.2
Flag_7seg_c      Alias PortB.3
Flag_7seg_d      Alias PortB.4
Flag_7seg_e      Alias PortB.5
Flag_7seg_f      Alias PortB.6
Flag_7seg_g      Alias PortB.7

'Crystal_1        Alias PINC.0
'Crystal_2        Alias PINC.1
'Crystal_3        Alias PINC.2
'Crystal_4        Alias PINC.3
Switch_Hex       Alias PINC.4
Switch_Export    Alias PINC.5       '' Algorithm (ALG) export in detailed-runtime

Switch_Run       Alias PIND.4       '' Switch
Switch_ZRNG      Alias PIND.5       '' Mixy
Switch_YRNG      Alias PIND.6       '' Truly
Switch_XRNG      Alias PIND.7       '' Noisy


'==============================================================================
' FUNCTION & ROUTINE ARCHITECTURE PROTOTYPES
'==============================================================================
' General Strobes
Dim Current_streaming As Byte
Dim Current_nibbles As DWord
Dim Cast_single As Single
Dim RND_base As String * 5

Declare Sub Self_audit()
Declare Sub ShutterChaos()
Declare Sub JitterChaos()
Declare Sub JitterRefresh()

Declare Sub ShutterStrobe()
Declare Sub JitterStrobe(ByVal I As Byte)
Declare Sub MixerStrobe()

Declare Function MultiBlock(ByVal Block_type As String * 10) As Dword
Declare Sub MultiStream()

'Declare Function WeakyFactor() As DWord
Declare Function NoisyFactor() As DWord
Declare Function MultiRandom(ByVal Rnd_type As String * 10) As Single
Declare Function MultiRandRange(ByVal RandRange_Type As String * 7 , ByVal MinVal As Single, ByVal MaxVal As Single) As Single

Declare Function Mix32(ByVal X As DWord) As DWord
Declare Function Rotl32(ByVal X As DWord , ByVal N As Byte) As DWord
Declare Function Floor(ByVal Value As Single) As Long

'Declare Sub ShuffleSettings()
Declare Function AngleForTopFace(ByVal TopFace As Byte) As Single
Declare Function FaceFromAngle(ByVal Theta As Single , ByVal Which As String) As Byte
Declare Sub Vertices(ByVal X As Single , ByVal Y As Single , ByVal Theta As Single , ByVal Half As Single)
Declare Function GravityAtAltitude(ByVal Km As Single) As Single
Declare Function CollideAndResolve(ByVal Restitution As Single , ByVal Friction As Single , ByVal Adhesion As Single , ByVal Mass As Single , ByVal I_inertia As Single , ByVal Half As Single) As Byte

Declare Function NRNG() As Byte   ' Noisy Random Number Generator
Declare Function TRNG() As Byte   ' Truly Random Number Generator
Declare Function MRNG() As Byte   ' Mixer Random Number Generator
Declare Function HRNG() As Byte   ' Hyper Random Number Generator

Declare Sub PrintLog(ByVal Msg As String * 30)
Declare Sub PrintEntropy(Byval isStreaming As Byte)
Declare Sub PrintJitter(Byval isStreaming As Byte)
Declare Sub PrintHistory(ByVal Msg As String * 20)
Declare Sub PrintValBits(ByVal Target_Acc As DWord, ByVal Msg As String * 20)
Declare Sub SendSessionJson()

Declare Sub Reset_led()
Declare Sub Manage_led(ByVal The_7seg As Byte , ByVal The_milisec As Integer , ByVal The_state As Byte)
Declare Sub ShowHexOn7Seg(ByVal HexVal As Byte , ByVal IsCommonAnode As Byte)

'==============================================================================
' SYSTEM MATERIAL LOGIC ARRAYS (1-Based Dimensions)
'==============================================================================
' DICE_MATERIALS: each row = [friction, restitution, damping]
Dim DICE_MATERIALS(4, 3) As Single
DICE_MATERIALS(1,1) = 0.55 : DICE_MATERIALS(1,2) = 0.35 : DICE_MATERIALS(1,3) = 0.02   ' Plastic
DICE_MATERIALS(2,1) = 0.45 : DICE_MATERIALS(2,2) = 0.45 : DICE_MATERIALS(2,3) = 0.08   ' Wood
DICE_MATERIALS(3,1) = 0.70 : DICE_MATERIALS(3,2) = 0.25 : DICE_MATERIALS(3,3) = 0.01   ' Metal
DICE_MATERIALS(4,1) = 0.40 : DICE_MATERIALS(4,2) = 0.60 : DICE_MATERIALS(4,3) = 0.18   ' Rubber

' SURFACE_MATERIALS: each row = [friction, restitution, damping]
Dim SURFACE_MATERIALS(6, 3) As Single
SURFACE_MATERIALS(1,1) = 0.50 : SURFACE_MATERIALS(1,2) = 0.40 : SURFACE_MATERIALS(1,3) = 0.10   ' Wood
SURFACE_MATERIALS(2,1) = 0.30 : SURFACE_MATERIALS(2,2) = 0.70 : SURFACE_MATERIALS(2,3) = 0.25   ' Carpet
SURFACE_MATERIALS(3,1) = 0.65 : SURFACE_MATERIALS(3,2) = 0.20 : SURFACE_MATERIALS(3,3) = 0.03   ' Glass
SURFACE_MATERIALS(4,1) = 0.70 : SURFACE_MATERIALS(4,2) = 0.25 : SURFACE_MATERIALS(4,3) = 0.01   ' Metal
SURFACE_MATERIALS(5,1) = 0.45 : SURFACE_MATERIALS(5,2) = 0.55 : SURFACE_MATERIALS(5,3) = 0.20   ' Rubber
SURFACE_MATERIALS(6,1) = 0.35 : SURFACE_MATERIALS(6,2) = 0.65 : SURFACE_MATERIALS(6,3) = 0.30   ' Felt

'==============================================================================
' PHYSICAL CONSTANTS
'==============================================================================
Const EARTH_RADIUS_KM = 6371.0
Const G0 = 9.81

'==============================================================================
' CONSOLIDATED GLOBAL CORE MATRIX VARIABLES (Unused UI Buffers Purged)
'==============================================================================

' String buffer to hold the intermediate text representation
Dim DiceMat As Byte
Dim SurfMat As Byte
Dim InitTop As Byte
Dim Temperature As Single
Dim Humidity As Single
Dim Altitude As Single

Dim Height As Single
Dim Simtime As Single
Dim Initomega As Single
Dim Final_top_g As Byte
Dim Sim_t As Single

' UI Formatted Text String Buffers
'Dim HeightStr As String * 8
'Dim InitOmegaStr As String * 8
'Dim SimTimeStr As String * 8

' Random Offset Noise Modifiers
Dim Noiseangle As Single
Dim Noiseomega As Single
Dim Noiseheight As Single
Dim Noiserest As Single
Dim Noisefric As Single
Dim Noiseadh As Single
Dim Noisetime As Single
Dim Noisealt As Single

' Simulation Flow State Trackers
Dim Remaining_Sim As Single
Dim Droptimerms As Long
Dim Seedfrozen As Byte
Dim I_counter As Long
Dim I_timer As Long


' Memory Calculation Buffers (Extracted Globally to satisfy Frame Limits)
Dim Face_pool(17) As Byte
Dim Facelabelslocal(4) As Byte
Dim Pool_len As Byte
Dim Temp_pool_len As Byte
Dim Physics_state(6) As Single
Dim Vertsx(4) As Single
Dim Vertsy(4) As Single

'' 7-Seg monitoring flags
Dim zoomin_by_time As Bit
Dim zoomin_by_dist As Bit
Dim zoomout_by_pv As Bit
Dim move_by_lv As Bit
Dim move_by_rv As Bit


' Static Lookup Reference Matrices
Dim SegMap(17) As Byte
SegMap(1)  = &B00111111       '0
SegMap(2)  = &B00000110       '1
SegMap(3)  = &B01011011       '2
SegMap(4)  = &B01001111       '3
SegMap(5)  = &B01100110       '4
SegMap(6)  = &B01101101       '5
SegMap(7)  = &B01111101       '6
SegMap(8)  = &B00000111       '7
SegMap(9)  = &B01111111       '8
SegMap(10) = &B01101111       '9
SegMap(11) = &B01110111       'A
SegMap(12) = &B01111100       'b
SegMap(13) = &B00111001       'C
SegMap(14) = &B01011110       'd
SegMap(15) = &B01111001       'E
SegMap(16) = &B01110001       'F
SegMap(17) = &B01000000       '-

Dim Rotconst(8) As Byte
Rotconst(1) = 3
Rotconst(2) = 5
Rotconst(3) = 11
Rotconst(4) = 17
Rotconst(5) = 23
Rotconst(6) = 29
Rotconst(7) = 7
Rotconst(8) = 13

' ==============================================================================
' ZERO-LOSS BITWISE CONVERSION CHANNELS (Add to top of your file)
' ==============================================================================
''Dim Stream_Float As Single                      ' Core Float [0.0, 1.0) Space
''Dim Stream_Long As Long At Stream_Float OVERLAY ' Shares the exact 4 bytes of RAM!


'==============================================================================
' HARDWARE INITIALIZATION INITIAL TEST SIGNALS
'==============================================================================
Call PrintLog("Welcome to Decent Dice..")

Call Manage_led(0 , 100 , 0)
Call Manage_led(0 , 100 , 1)
Call Manage_led(0 , 100 , 0)

I_counter = 0
I_timer = 0

Current_streaming = 0
Final_top_g = 16

Start Timer0
Start Timer1

'==============================================================================
' MAIN APPLICATION EXECUTION INTERFACE LOOP
'==============================================================================
Do
   If Switch_Run = 0 Then
      Call Reset_led()

      Call Manage_led(0 , 100 , 0)
      Call Manage_led(0 , 100 , 1)
      Call Manage_led(0 , 100 , 0)
      Call Manage_led(0 , 100 , 1)


      If Switch_XRNG = 0 And Switch_YRNG = 1 And Switch_ZRNG = 1 Then
         ' NRNG MODE
         Final_top_g = NRNG()
      ElseIf Switch_XRNG = 1 And Switch_YRNG = 0 And Switch_ZRNG = 1 Then
         ' TRNG MODE
         Final_top_g = TRNG()
      ElseIf Switch_XRNG = 1 And Switch_YRNG = 1 And Switch_ZRNG = 0 Then
         ' MRNG MODE
         Final_top_g = MRNG()


      ElseIf Switch_XRNG = 1 And Switch_YRNG = 0 And Switch_ZRNG = 0 Then
         ' HRNG MODE / Base RNG -> Noisy
         RND_base = "Noisy"
         Final_top_g = HRNG()
      ElseIf Switch_XRNG = 0 And Switch_YRNG = 1 And Switch_ZRNG = 0 Then
         ' HRNG MODE / Base RNG -> Truly
         RND_base = "Truly"
         Final_top_g = HRNG()
      ElseIf Switch_XRNG = 0 And Switch_YRNG = 0 And Switch_ZRNG = 1 Then
         ' HRNG MODE / Base RNG -> Mixy
         RND_base = "Mixy"
         Final_top_g = HRNG()


      ElseIf Switch_XRNG = 0 And Switch_YRNG = 0 And Switch_ZRNG = 0 Then
         ' Check health of crystals + clock source of flip-flop
         Call Self_audit()
         Final_top_g = 17
      Else
         ' Nothing to do! show negative setting
         Final_top_g = 16
      End If


      Call ShowHexOn7Seg(Final_top_g , 1)

      Call Manage_led(0 , 100 , 0)
      Call Manage_led(0 , 100 , 1)
      Call Manage_led(0 , 100 , 0)
   End If

   If Current_streaming <> 0 Then       ' 0 = STOP STREAMING
      Call MultiStream()
      Call Reset_led()
   End If

Loop
End

'==============================================================================
' SUBROUTINE & FUNCTION ALGORITHM IMPLEMENTATIONS
'==============================================================================

Sub Reset_led()

   ' Reset 7-segment visualizer LEDs
   PORTB = &B11111110

End Sub

'------------------------------------------------------------------------------
Sub Self_audit()

      ' Engage ShutterChaos
      Call ShutterChaos()
      Waitms 305                     '' Extra time for visual audit

End Sub

'------------------------------------------------------------------------------
Sub ShutterChaos()

   Local Chaotic_pair1 As Byte
   Local Chaotic_pair2 As Byte
   Local Portb_Mask As Byte

   ' Scratchpad byte variables to safely hold inverted crystal states
   Local Inv_Crystals As Byte
   Local Inv_Pairs As Byte

   Call Reset_led()

   ' 1. Take the high-speed one-shot snapshot
   Current_nibbles = PINC And &B00001111

   ! NOP

   ' 2. Calculate raw pairs using safe byte operations
   Chaotic_pair1 = Current_nibbles.0 Xor Current_nibbles.2
   Chaotic_pair2 = Current_nibbles.1 Xor Current_nibbles.3

   ' ==============================================================================
   ' STRATEGIC CYCLE-FRICTION: Destabilizes power rail lock by varying loop path length
   ' ==============================================================================
   If Chaotic_pair1.0 = 1 Then
      ! NOP
   End If

   ' ==============================================================================
   ' HANG-SAFE BITMASK GENERATION: Uses clean byte-math to prevent register corruption
   ' ==============================================================================
   ' Perform the inversions at the BYTE level first, protecting the stack bounds
   Inv_Crystals = Not Current_nibbles

   ' Construct the final display mask step-by-step using pristine assignments
   'Portb_Mask.1 = 0                     ' Keep Segment A line low
   Portb_Mask.1 = 1                     ' Keep Segment A line high
   Portb_Mask.2 = Inv_Crystals.3        ' Segment B Map (Safe inverted assignment)
   Portb_Mask.3 = Inv_Crystals.2        ' Segment C Map
   Portb_Mask.5 = Inv_Crystals.0        ' Segment E Map
   Portb_Mask.6 = Inv_Crystals.1        ' Segment F Map
   'Portb_Mask.2 = 1        ' Keep Segment B Map high
   'Portb_Mask.3 = 1        ' Keep Segment C Map high
   'Portb_Mask.5 = 1        ' Keep Segment E Map high
   'Portb_Mask.6 = 1        ' Keep Segment F Map high
   Portb_Mask.0 = 1                      ' Keep DP line high

   Inv_Pairs = Not Chaotic_pair2
   Portb_Mask.4 = Inv_Pairs.0           ' Segment D Map (Uses bit 0 of inverted byte)
   Inv_Pairs = Not Chaotic_pair1
   Portb_Mask.7 = Inv_Pairs.0           ' Segment G Map

   ' 3. Synchronous Hardware Push: Fires both lines exactly together on a single clock cycle
   PORTB = Portb_Mask

End Sub


'------------------------------------------------------------------------------
Sub JitterChaos()

   ' Needed time between interrupts: ~32 microseconds.
   ' MCU Performance: This provides the exact same perfect timing window as the 32 kHz watch crystal.
   ' Your Isr_intx routine (which takes ~24.75 microseconds) will finish completely, clear out, and
   ' wait smoothly for the next edge without hitting the 198-cycle hardware blind spot.

   Local Pointer_J2 As Byte
   Local Pointer_J3 As Byte
   Local Temp_Slip As Byte

   Block_J2_Index = 0
   Block_J3_Index = 0

   ' Clear hardware interrupt flags and open the gates
   EIFR = &B00000011
   Enable Int0
   Enable Int1

   ' Wait until timing jitter collected across both blocks
   While Block_J2_Index < 32 Or Block_J3_Index < 32

      ' Execute the high-speed bitmask capture and 7-segment strobe pass
      Call ShutterChaos()

      ' Micro-slip delay buffer to allow background ISR processing space
      Waitus 8

      ' ==============================================================================
      ' BGN: DYNAMIC MULTI-BIT DIFFERENTIAL PHASE-SLIP EXTENSION
      ' ==============================================================================
      ' 1. Capture atomic snapshots of both volatile global index trackers
      Pointer_J2 = Block_J2_Index
      Pointer_J3 = Block_J3_Index

      ' 2. Enforce safety checks to ensure arrays have populated initial indices
      If Pointer_J2 > 0 And Pointer_J3 > 0 Then

         ' PATH A: INT0 Harvesting Pipeline is running ahead of INT1
         If Pointer_J2 > Pointer_J3 Then
            ' Extract a 2-bit sliding delay mask using the low bits of Block_J2
            Temp_Slip = Block_J2(pointer_j2).0 Xor Block_J2(pointer_j2).1
            If Temp_Slip <> 0 Then ! NOP
            If Block_J2(pointer_j2).2 = 1 Then
               ! NOP
               ! NOP
            End If

         ' PATH B: INT1 Harvesting Pipeline is running ahead of INT0
         Elseif Pointer_J3 > Pointer_J2 Then
            ' Extract an unaligned 2-bit sliding delay mask from Block_J3 instead
            Temp_Slip = Block_J3(pointer_j3).0 Xor Block_J3(pointer_j3).1
            If Temp_Slip <> 0 Then ! NOP
            If Block_J3(pointer_j3).2 = 1 Then
               ! NOP
               ! NOP
            End If

         ' PATH C: Hard Synchronous Alignment (Both pipelines are tracking identically)
         Else
            ' Force an intentional 3-cycle asymmetric fracture to break loop parity
            ! NOP
            ! NOP
            ! NOP
         End If

      End If
      ' ==============================================================================
      ' END: DYNAMIC MULTI-BIT DIFFERENTIAL PHASE-SLIP EXTENSION
      ' ==============================================================================

   Wend

   Disable Int0
   Disable Int1

End Sub

'------------------------------------------------------------------------------
Sub JitterRefresh()

   'Call PrintLog("Begin Jitter_Strobe")
   Call PrintLog("-> Shutter_Chaos <-")
   Call JitterChaos()
   Call PrintJitter(0)
   Call PrintLog(" ")
   'Call PrintLog("End Jitter_Strobe")

End Sub

'------------------------------------------------------------------------------
Sub ShutterStrobe()

   ' Read live states of the 4 crystals from Port C (pins 1 to 4)
   Current_nibbles = PINC And &B00001111

End Sub

'------------------------------------------------------------------------------
Sub JitterStrobe(ByVal I As Byte)

   Local Jitter_Window_2 As Byte
   Local Jitter_Window_3 As Byte
   Local Jitter_Window As Byte

   '' Refresh dual-jitter arrays
   If I = 18 Then
      'Call PrintLog("-> Jitter_Refresh <-")
      Call JitterRefresh()
   End If

   'Call PrintLog(" ")
   Call PrintLog("Begin Jitter_Strobe")

   '-------------------------------------------------------------------------
   ' PASS A: INT0 3-LSB (Left / Bits 29-31) vs. Balanced Shutter (Right / Bits 0-2)
   '-------------------------------------------------------------------------
   ' 1. Extract the raw 3-bit quantum window from the Block_J2 array element
   Jitter_Window_2 = Block_J2(I) And &B00001111
   Jitter_Window_3 = Block_J3(I) And &B00001111
   Current_nibbles = Jitter_Window_2 Xor Jitter_Window_3 ' Vectorized 3-bit cross-coupling
   Jitter_Window = Current_nibbles And &B00001111

   ' LEFT SIDE INJECTION: Inject the 3-bit hardware jitter value into Jitter_Acc MSB boundary
   If Switch_Export = 0 Then
      Print "Block_J2("; Str(I); "): "; Str(Block_J2(I))
      Print "Jitter_Window_2: "; Bin(jitter_window_2)
      Print "Block_J3("; Str(I); "): "; Str(Block_J3(I))
      Print "Jitter_Window_3: "; Bin(jitter_window_3)
      Print "JW2 xor JW3: "; Bin(Jitter_Window)
   End If

   Call PrintLog("End Jitter_Strobe")

End Sub


'------------------------------------------------------------------------------
Sub MixerStrobe()

   Local Shutter_Window As Byte
   Local Jitter_Window As Byte

   Local Jitter_Acc As DWord
   Local I As Byte

   Call PrintLog("Begin Mixer_Strobe")
   Call JitterRefresh()

   '' 1. Build a 32-bit accumulator
   '==============================================================================
   ' UPGRADED: 64-Step Balanced 1-Bit Left / 1-Bit Right Entropy Pipeline
   '==============================================================================

   Jitter_Acc = MultiBlock("Shutter")
   Call PrintValBits(Jitter_Acc, "_____Init Shutter")

   Jitter_Acc = Jitter_Acc Xor &H9E3779B9
   Call PrintValBits(Jitter_Acc, "________Init Seed")


   ' Ensure these variables are declared as Byte in your global configuration
   ' Local/Global variables: Shutter_Window (Byte), Jitter_Window (Byte)

   For I = 1 To 32
       If Switch_Export = 0 Then
          Print " "
          Print "For-Loop: "; Str(I)
       End If

       '-------------------------------------------------------------------------
       ' PASS A: INT0 3-LSB (Left / Bits 29-31) vs. Balanced Shutter (Right / Bits 0-2)
       '-------------------------------------------------------------------------
       ' 1. Extract the raw 3-bit quantum window from the Block_J2 array element
       Jitter_Window = Block_J2(I) And &B00000111

       ' 2. Capture live environmental side-channel noise via ShutterStrobe
       Call ShutterStrobe()

       ' 3. Collapse the 4-bit crystal snapshot into a uniform 3-bit window
       Shutter_Window.0 = Current_nibbles.0 Xor Current_nibbles.3
       Shutter_Window.1 = Current_nibbles.1
       Shutter_Window.2 = Current_nibbles.2

       If Switch_Export = 0 Then
          Print " "
          Print "Shutter_Window_3B: "; Bin(shutter_window)
       End If

       ' RIGHT SIDE INJECTION: Inject the 3-bit shutter value directly into Jitter_Acc LSB boundary
       If Shutter_Window.0 <> 0 Then Toggle Jitter_Acc.0
       If Shutter_Window.1 <> 0 Then Toggle Jitter_Acc.1
       If Shutter_Window.2 <> 0 Then Toggle Jitter_Acc.2

       Call PrintValBits(Jitter_Acc, "P1.Right 3Bit XOR")

       ' LEFT SIDE INJECTION: Inject the 3-bit hardware jitter value into Jitter_Acc MSB boundary
       If Switch_Export = 0 Then
          Print "Block_J2("; Str(I); "): "; Str(Block_J2(I))
          Print "Jitter_Window_BJ2: "; Bin(jitter_window)
       End If

       If Jitter_Window.0 <> 0 Then Toggle Jitter_Acc.29
       If Jitter_Window.1 <> 0 Then Toggle Jitter_Acc.30
       If Jitter_Window.2 <> 0 Then Toggle Jitter_Acc.31

       Call PrintValBits(Jitter_Acc, "_P1.Left 3Bit XOR")
       ' 5. First Avalanche Pass
       Jitter_Acc = Mix32(Jitter_Acc)
       Call PrintValBits(Jitter_Acc, "_________P1.Mixer")

       '-------------------------------------------------------------------------
       ' PASS B: Whitened Cross-Couple (Left / Bits 29-31) vs. Fresh Shutter (Right / Bits 0-2)
       '-------------------------------------------------------------------------
       ' 1. Capture a fresh live side-channel environmental snapshot
       Call ShutterStrobe()

       ' 2. Collapse the new fresh 4-bit crystal snapshot into a 3-bit window
       Shutter_Window.0 = Current_nibbles.0 Xor Current_nibbles.3
       Shutter_Window.1 = Current_nibbles.1
       Shutter_Window.2 = Current_nibbles.2

       If Switch_Export = 0 Then
          Print " "
          Print "Shutter_Window_3B: "; Bin(shutter_window)
       End If

       ' RIGHT SIDE INJECTION: Inject fresh shutter parity into bits 0, 1, 2
       If Shutter_Window.0 <> 0 Then Toggle Jitter_Acc.0
       If Shutter_Window.1 <> 0 Then Toggle Jitter_Acc.1
       If Shutter_Window.2 <> 0 Then Toggle Jitter_Acc.2

       Call PrintValBits(Jitter_Acc, "P2.Right 3Bit XOR")

       ' 3. Cross-couple both 3-bit windows to erase loop execution grid bias
       ' Isolate Block_J3 3 LSBs and XOR directly with our previous J2 window
       Jitter_Window = Block_J3(I) And &B00000111
       Jitter_Window = Jitter_Window Xor Block_J2(I) ' Vectorized 3-bit cross-coupling

       ' Force absolute 3-bit isolation before registration to kill high-order junk bytes
       Jitter_Window = Jitter_Window And &B00000111

       ' LEFT SIDE INJECTION: Inject cross-coupled 3-bit vector into bits 29, 30, 31
       If Switch_Export = 0 Then
          Print "Block_J3("; Str(I); "): "; Str(Block_J3(I))
          Print "Cross_Window_BJ23: "; Bin(jitter_window)
       End If

       If Jitter_Window.0 <> 0 Then Toggle Jitter_Acc.29
       If Jitter_Window.1 <> 0 Then Toggle Jitter_Acc.30
       If Jitter_Window.2 <> 0 Then Toggle Jitter_Acc.31

       Call PrintValBits(Jitter_Acc, "_P2.Left 3Bit XOR")
       ' 6. Second Avalanche Pass
       Jitter_Acc = Mix32(Jitter_Acc)
       Call PrintValBits(Jitter_Acc, "_________P2.Mixer")

   Next I


   'Extracting only the lower 4 bits preserves full entropy. The jitter source provides
   '~6-10 bits total, and Mix32 spreads this uniformly across the 32-bit accumulator.
   'By taking fewer bits than the entropy budget, each output bit remains unbiased:
   '  - 4-bit output  -> ~0.95-1.00 bits of entropy per bit (ideal)
   '  - 8-bit output  -> ~0.75 bits of entropy per bit
   '  - 32-bit output -> ~0.20-0.30 bits of entropy per bit

   Current_nibbles = Jitter_Acc And &B00001111

   Call PrintLog("End Mixer_Strobe")

End Sub


'------------------------------------------------------------------------------
Function MultiBlock(ByVal Block_type As String * 10) As Dword
    Local I As Byte
    Local J As Byte
    Local Sample As Byte
    Local Result As Dword

    Call PrintLog("Begin Block_" + Block_type)

    Result = 0

    For I = 1 To 8

      If Block_type = "Mixer" Then
         ' Read the raw bits from Timing Jitter
         Call MixerStrobe()
         Sample = Current_nibbles
      ElseIf Block_type = "Jitter" Then
         ' Read the raw bits from Timing Jitter
         J = I + 17 '' from 18 to 24
         Call JitterStrobe(J)
         Sample = Current_nibbles
      ElseIf Block_type = "Shutter" Then
         ' Read the raw bits from port pins
         Call ShutterStrobe()
         Sample = Current_nibbles
      End If

      ' Pack the pure raw bits directly into the unsigned Dword container (4 bits per loop)
      Shift Result , Left , 4
      Result = Result Or Sample

      ' 2. Drive your existing 7-segment visualizer LEDs
      Call PrintLog("Entropy_Round(" + Str(I) + "): ")
      Call PrintEntropy(0)
      Call PrintLog(" ")

    Next I

    Call PrintValBits(Result, "_Harvested Block")
    Call PrintLog("End Block_" + Block_type)

    MultiBlock = Result
End Function

'------------------------------------------------------------------------------
Function MultiRandom(ByVal Rnd_type As String * 10) As Single

    Local Mfe_i As Byte
    Local Shift_amount As Byte

    Local Crypto32 As Dword
    Local L As Dword
    Local Temp As Single

    Call PrintLog("Begin Random_" + Rnd_type)

    If Rnd_type = "Mixy" Then
       Crypto32 = MultiBlock("Mixer")
    ElseIf Rnd_type = "Truly" Then
       Crypto32 = MultiBlock("Jitter")
    ElseIf Rnd_type = "Noisy" Then
       Crypto32 = NoisyFactor()
    End If

   '--------------------------------------------------------------
   ' MSB Magnitude Collapse:
   ' Right-shifting a 32-bit value removes the MSB and halves the
   ' numeric range each time. The original upper-half range
   ' [2^31 .. 2^32-1] shrinks as follows:
   '
   ' Shift 0 : Range = 2147483647   (2^31 - 1)
   ' Shift 1 : Range = 1073741823   (2^30 - 1)
   ' Shift 2 : Range =  536870911   (2^29 - 1)
   ' Shift 3 : Range =  268435455   (2^28 - 1)
   ' Shift 4 : Range =  134217727   (2^27 - 1)
   ' Shift 5 : Range =   67108863   (2^26 - 1)
   ' Shift 6 : Range =   33554431   (2^25 - 1)
   ' Shift 7 : Range =   16777215   (2^24 - 1)
   ' Shift 8 : Range =    8388607   (2^23 - 1)
   ' Shift 9 : Range =    4194303   (2^22 - 1)
   ' Shift 10: Range =    2097151   (2^21 - 1)
   '
   ' This shows the MSB contributes the entire 2^31 magnitude.
   ' Removing it (or fixing it) stabilizes magnitude and leaves
   ' a clean 31-bit entropy block ("Magnitude Freed").
   '--------------------------------------------------------------
   '--------------------------------------------------------------
   ' Magnitude Freed Block:
   ' Rotate-left until MSB = 1. This circular scan guarantees that
   ' one of the 31 entropy bits eventually reaches the MSB position.
   '
   ' Based on the magnitude-collapse table:
   ' Removing the MSB (or fixing it) stabilizes numeric magnitude.
   ' The MSB contributes the entire 2^31 jump; shifting right shows
   ' the range halves each time (2^31-1, 2^30-1, ..., 2^21-1).
   '
   ' By rotating until MSB=1, we neutralize magnitude dominance and
   ' obtain a stable 31-bit entropy block ("Magnitude Freed").
   '--------------------------------------------------------------

   '--------------------------------------------------------------
   ' Magnitude Freed normalization (31-bit entropy)
   '--------------------------------------------------------------
   For Mfe_i = 0 To 31
      ' Calculate branchless shift: 1 if MSB is 0, 0 if MSB is 1
      Shift_amount = 1 - Crypto32.31

      ' Execute inline rotation without conditional jumps
      Crypto32 = Rotl32(Crypto32 , Shift_amount)

      Call PrintValBits(Crypto32, "_Magnitude Freed")
   Next Mfe_i

   '--------------------------------------------------------------
   ' Magnitude Freed preserved
   '--------------------------------------------------------------
   ' Remove fixed MSB magnitude (31-bit entropy)
   L = Crypto32 - 2147483648          ' subtract 2^31

   Call PrintValBits(L, "______Normalized")

   '--------------------------------------------------------------
   ' Magnitude Freed normalized 31-bit entropy to [0,1)
   '--------------------------------------------------------------
   Temp = L
   Temp = Temp / 2147483648.0         ' divide by exact 2^31

   Call PrintLog("   <--" + " RANDOM: " + Str(Temp))
   Call PrintLog("End Random_" + Rnd_type)

   MultiRandom = Temp
End Function


'------------------------------------------------------------------------------
' Unbiased inclusive integer range [MinVal, MaxVal]
'------------------------------------------------------------------------------
Function MultiRandRange(ByVal RandRange_Type As String * 7 , ByVal MinVal As Single, ByVal MaxVal As Single) As Single
    Local Rnd_Val As Single
    Local Span As Single

    Rnd_Val = MultiRandom(RandRange_Type)

    Span = MaxVal - MinVal
    Span = Span + 1                  ' inclusive
    Span = Rnd_Val * Span
    Span = Span + MinVal

    Call PrintLog(" ")
    Call PrintLog("   <--" + RandRange_Type + "_Rand_Range: " + Str(Span))

    MultiRandRange = Span
End Function


'------------------------------------------------------------------------------
Sub MultiStream()

   Local Xrng As Byte

   ' ------------------------------------------------------------
   If Current_streaming = 1 Then
      ' Read live crystals
      Call ShutterStrobe()
      Call PrintEntropy(1)
   ElseIf Current_streaming = 2 Then
      ' Read live flip-flop
      Call JitterChaos()
      Call PrintJitter(1)
      Waitms 305                     '' Extra Time for Transfer Dual-Jitter Arrays
   ElseIf Current_streaming = 3 Then
      ' Generate Noisy-RNG
      Xrng = NRNG()
      Print Str(Xrng);"n";
   ElseIf Current_streaming = 4 Then
      ' Generate True-RNG
      Xrng = TRNG()
      Print Str(Xrng);"t";
   ElseIf Current_streaming = 5 Then
      ' Generate Mixer-RNG
      Xrng = MRNG()
      Print Str(Xrng);"m";
   ElseIf Current_streaming = 6 Then
      ' Generate Hyper-RNG / Noisy
      RND_base = "Noisy"
      Xrng = HRNG()
      Print Str(Xrng);"hn";
   ElseIf Current_streaming = 7 Then
      ' Generate Hyper-RNG / Truly
      RND_base = "Truly"
      Xrng = HRNG()
      Print Str(Xrng);"ht";
   ElseIf Current_streaming = 8 Then
      ' Generate Hyper-RNG / Mixy
      RND_base = "Mixy"
      Xrng = HRNG()
      Print Str(Xrng);"hm";
   End IF
   ' ------------------------------------------------------------

   Waitms 15
   Call Manage_led(0 , 0 , 1)

   Waitms 15
   Call Manage_led(0 , 0 , 0)

End Sub


'------------------------------------------------------------------------------
Function NoisyFactor() As DWord
    Local T1 As Single
    Local T2 As Single
    Local Arg1 As Single
    Local Arg2 As Single
    Local Norm1 As Single
    Local Norm2 As Single
    Local A_single As Single
    Local B_single As Single
    Local C_single As Single
    Local D_single As Single
    Local Twopi As Single
    ''Local Temp_sng As Single

    Local Noisycallcounter_jump As Long
    Local Timerms As Long
    Local Ia As Long
    Local Ib As Long
    Local Ic As Long
    Local Id As Long
    Local Nt As Long
    Local Temp As Long

    Local Ns As DWord
    Local Crypto32 As DWord
    Local Uniform32 As DWord

    ' Temporary helper variables required for explicit type casting / calculation steps
    Local Cast_sng As Single
    Local Calc_sng As Single

    Twopi = 2.0 * 3.14159265

    Call PrintLog("-> Noisy_Factor <-")
    Call PrintLog("_____TIMER: " + Str(i_timer))
    Call PrintLog("___COUNTER: " + Str(i_counter))

    Noisycallcounter_jump = I_timer Mod 10
    I_counter = I_counter + 1
    I_counter = I_counter + Noisycallcounter_jump

    Timerms = I_counter Mod 10
    Timerms = I_timer + Timerms

    ' Fix: Explicitly cast Long to Single, then do the math
    Cast_sng = Timerms
    T1 = Cast_sng * 0.01

    ' Fix: Explicitly cast global Long to Single
    T2 = I_counter

    Arg1 = T1 * 12.9898
    Arg2 = T1 * T1
    Arg2 = Arg2 * 0.125
    Arg1 = Arg1 + Arg2

    ' Fix: Floating-point math split into discrete steps
    Calc_sng = Arg1 / Twopi
    Temp = Int(calc_sng)       ' Note: Ensure Int() matches your AVR compilation goals
    Cast_sng = Temp
    Arg2 = Cast_sng * Twopi
    Arg1 = Arg1 - Arg2

    Arg2 = T2 * 78.233
    B_single = T2 * T2
    B_single = B_single * 0.375
    Arg2 = Arg2 + B_single

    ' Fix: Floating-point math split into discrete steps
    Calc_sng = Arg2 / Twopi
    Temp = Int(calc_sng)
    Cast_sng = Temp
    B_single = Cast_sng * Twopi
    Arg2 = Arg2 - B_single

    ' Fix: Variable casing synchronized to match lowercase declarations
    Norm1 = Cos(arg1)
    Norm2 = Cos(arg2)

    A_single = Sin(arg1)
    B_single = Tanh(norm1)    ' Note: Ensure your BASCOM version includes the Tanh library
    C_single = Sin(arg2)
    D_single = Tanh(norm2)

    A_single = A_single + 1.0
    A_single = A_single * 500.0
    Ia = Int(a_single)

    B_single = B_single + 1.0
    B_single = B_single * 500.0
    Ib = Int(b_single)

    C_single = C_single + 1.0
    C_single = C_single * 500.0
    Ic = Int(c_single)

    D_single = D_single + 1.0
    D_single = D_single * 500.0
    Id = Int(d_single)

    Ia = Ia And &H03FF
    Shift Ia , Left , 22
    Nt = Ia

    Ib = Ib And &H03FF
    Shift Ib , Left , 12
    Nt = Nt Or Ib

    Ic = Ic And &H03FF
    Shift Ic , Left , 2
    Nt = Nt Or Ic

    Id = Id And &H0003
    Nt = Nt Or Id

    Ns = Mix32(nt)
    Call PrintLog("-> TRIGONOMETRY: " + Str(Ns))

    Crypto32 = MultiBlock("Shutter")
    Call PrintLog("-> SHUTTER: " + Str(Crypto32))

    Uniform32 = Crypto32 Xor Ns

    Call PrintValBits(Uniform32, "_Harvested Noise")

    NoisyFactor = Uniform32
End Function

'------------------------------------------------------------------------------
' 32-bit Unsigned Mix Function (Matches JS mix32 exactly)
'------------------------------------------------------------------------------
Function Mix32(ByVal X As DWord) As DWord
    Local Temp As DWord

    ' x ^= x >>> 16;
    Temp = X
    Shift Temp , Right , 16
    X = X Xor Temp

    ' x = Math.imul(x, 0x7feb352d);
    ' 0x7feb352d = 2146055469 (Unsigned)
    X = X * 2146055469

    ' x ^= x >>> 15;
    Temp = X
    Shift Temp , Right , 15
    X = X Xor Temp

    ' x = Math.imul(x, 0x846ca68b);
    ' 0x846ca68b = 2221687435 (Unsigned)
    X = X * 2221687435

    ' x ^= x >>> 16;
    Temp = X
    Shift Temp , Right , 16
    X = X Xor Temp

    ' return x >>> 0; (Handled natively by Dword return type)
    Mix32 = X
End Function

'------------------------------------------------------------------------------
Function Rotl32(ByVal X As DWord , ByVal N As Byte) As DWord
    Local Temp_left As DWord
    Local Temp_right As DWord
    Local Right_shift_amt As Byte

    Temp_left = X
    Shift Temp_left , Left , N

    Right_shift_amt = 32 - N
    Temp_right = X
    Shift Temp_right , Right , Right_shift_amt

    X = Temp_left Or Temp_right
    Rotl32 = X
End Function

' ==============================================================================
' FUNCTION: Floor
' PURPOSE: Replaces BASCOM's irregular Int() to deliver an exact, IEEE-754
'          compliant mathematical floor across both positive and negative bounds.
' ==============================================================================
Function Floor(ByVal Value As Single) As Long
   Local Truncated As Long
   Local Cast_Sng As Single
   Local Remainder As Single

   ' 1. Fix() cuts off the decimal directly towards zero (Safe truncation)
   Truncated = Fix(value)

   ' 2. Isolate the fractional remainder by subtracting the integer part
   Cast_Sng = Truncated
   Remainder = Value - Cast_Sng

   ' 3. Gating: If there is a negative fractional remainder, step down by exactly 1
   '    This bypasses direct float comparison bugs on the AVR architecture safely.
   If Remainder < 0.0 Then
      Decr Truncated
   End If

   Floor = Truncated
End Function


'------------------------------------------------------------------------------
Function AngleForTopFace(ByVal TopFace As Byte) As Single
    Local Temp_multiplier As Single
    Local Half_pi As Single
    Local Final_angle As Single

    Temp_multiplier = 2.0 - TopFace
    Half_pi = 3.14159265 / 2.0
    Final_angle = Temp_multiplier * Half_pi
    AngleForTopFace = Final_angle
End Function

'------------------------------------------------------------------------------
Function FaceFromAngle(ByVal Theta As Single , ByVal Which As String) As Byte
    Local Th As Single
    Local Idx_long As Long
    Local Idx As Byte
    Local Twopi As Single
    Local Temp_div As Long
    Local Temp_calc As Single
    Local Quarter_pi As Single
    Local Half_pi As Single

    Twopi = 2.0 * 3.14159265
    Half_pi = 3.14159265 / 2.0
    Quarter_pi = 3.14159265 / 4.0

    Temp_div = Theta / Twopi
    Temp_calc = Temp_div * Twopi
    Th = Theta - Temp_calc
    Th = Th + Twopi
    Temp_div = Th / Twopi
    Temp_calc = Temp_div * Twopi
    Th = Th - Temp_calc

    Temp_calc = Th + Quarter_pi
    Temp_calc = Temp_calc / Half_pi

    ' Old Line: Idx_long = Int(temp_calc)
    ' UPDATED: Replaced with safe Floor() function to align sign transitions perfectly
    Idx_long = Floor(temp_calc)

    Idx_long = Idx_long Mod 4
    Idx = Idx_long

    If Which = "bottom" Then
        FaceFromAngle = Idx
    Else
        Idx = Idx + 2
        Idx_long = Idx Mod 4
        FaceFromAngle = Idx_long
    End If
End Function

'------------------------------------------------------------------------------
Sub Vertices(ByVal X As Single , ByVal Y As Single , ByVal Theta As Single , ByVal Half As Single)
    Local C As Single , S As Single
    Local Lx As Single , Ly As Single
    Local I As Byte
    Local Temp1 As Single , Temp2 As Single

    C = Cos(theta)
    S = Sin(theta)

    For I = 1 To 4
        Select Case I
            Case 1 : lx = 0.0 - Half : ly = 0.0 - Half
            Case 2 : lx = Half       : ly = 0.0 - Half
            Case 3 : lx = Half       : ly = Half
            Case 4 : lx = 0.0 - Half : ly = Half
        End Select

        ' 1. Calculate X Coordinate and store directly in the global array
        Temp1 = Lx * C
        Temp2 = Ly * S
        Temp1 = Temp1 - Temp2
        Vertsx(i) = X + Temp1

        ' 2. Calculate Y Coordinate and store directly in the global array
        Temp1 = Lx * S
        Temp2 = Ly * C
        Temp1 = Temp1 + Temp2
        Vertsy(i) = Y + Temp1
    Next
End Sub

'------------------------------------------------------------------------------
Function GravityAtAltitude(ByVal Km As Single) As Single
    Local R As Single
    Local Ratio As Single
    Local Ratio_squared As Single

    R = Earth_radius_km + Km
    Ratio = Earth_radius_km / R
    Ratio_squared = Ratio * Ratio
    GravityAtAltitude = G0 * Ratio_squared
End Function


'------------------------------------------------------------------------------
Function CollideAndResolve(ByVal Restitution As Single , ByVal Friction As Single , ByVal Adhesion As Single , ByVal Mass As Single , ByVal I_inertia As Single , ByVal Half As Single) As Byte
    ' Clean, one-per-line declarations prevent frame-pointer calculation bugs
    Local X As Single
    Local Y As Single
    Local Th As Single
    Local Vx As Single
    Local Vy As Single
    Local Om As Single
    Local Miny As Single
    Local R0 As Single
    Local R1 As Single
    Local Jn As Single
    Local Jt As Single
    Local Temp1 As Single
    Local Temp2 As Single
    Local Idx_c As Byte
    Local Loop_i As Byte

    ' Clean local variables to insulate impulses from velocities
    Local Contact_Vt As Single
    Local Contact_Vn As Single
    Local Inv_Mn As Single
    Local Inv_Mt As Single
    Local Max_Fric As Single

    ' 1. Unpack directly from the GLOBAL state vector
    X = Physics_state(1)
    Y = Physics_state(2)
    Th = Physics_state(3)
    Vx = Physics_state(4)
    Vy = Physics_state(5)
    Om = Physics_state(6)

    ' 2. Compute square vertices (Updating global Vertsx/Vertsy directly)
    Call Vertices(x , Y , Th , Half)

    ' 3. Find lowest vertex
    Miny = 1.0E+30
    Idx_c = 1
    For Loop_i = 1 To 4
        If Vertsy(loop_i) < Miny Then
            Miny = Vertsy(loop_i)
            Idx_c = Loop_i
        End If
    Next

    ' If minY >= 0 return false
    If Miny >= 0.0 Then
        CollideAndResolve = 0
        Exit Function
    End If

    ' 4. Relative contact point vectors: r = [px - x, py - y]
    R0 = Vertsx(Idx_c) - X
    R1 = Vertsy(Idx_c) - Y

    ' 5. Contact velocities unlinked from impulse accumulators (Jn, Jt)
    Temp1 = Om * R1
    Contact_Vt = Vx - Temp1

    Temp1 = Om * R0
    Contact_Vn = Vy + Temp1

    ' 6. Normal Impulse Calculation (jn) broken into single-line steps
    Inv_Mn = R0 * R0
    Inv_Mn = Inv_Mn / I_inertia
    Temp1 = 1.0 / Mass
    Inv_Mn = Inv_Mn + Temp1

    Jn = 0.0

    If Contact_Vn < 0.0 Then
        Jn = 1.0 + Restitution
        Jn = 0.0 - jn
        Jn = Jn * Contact_Vn
        Jn = Jn / Inv_Mn
    End If

    Temp1 = Abs(Contact_Vn)
    If Temp1 < 0.8 Then
        Temp1 = 0.0 - Adhesion
        Temp1 = Temp1 * 0.15
        Temp1 = Temp1 * Mass
        Jn = Jn + Temp1
    End If

    ' 7. Tangential Impulse Calculation (jt) broken into single-line steps
    Inv_Mt = R1 * R1
    Inv_Mt = Inv_Mt / I_inertia
    Temp1 = 1.0 / Mass
    Inv_Mt = Inv_Mt + Temp1

    Temp2 = 0.0 - Contact_Vt
    Jt = Temp2 / Inv_Mt

    Max_Fric = Friction * Abs(jn)
    Temp2 = 0.0 - Max_Fric
    If Jt < Temp2 Then Jt = Temp2
    If Jt > Max_Fric Then Jt = Max_Fric

    ' 8. Apply forces to update kinematic properties
    Temp1 = Jt / Mass
    Vx = Vx + Temp1

    Temp1 = Jn / Mass
    Vy = Vy + Temp1

    Temp1 = R0 * Jn
    Temp2 = R1 * Jt
    Temp1 = Temp1 - Temp2
    Temp1 = Temp1 / I_inertia
    Om = Om + Temp1

    Y = Y - Miny
    Y = Y - 0.000001

    ' 9. Pack updated states back directly into the GLOBAL matrix array
    Physics_state(1) = X
    Physics_state(2) = Y
    Physics_state(3) = Th
    Physics_state(4) = Vx
    Physics_state(5) = Vy
    Physics_state(6) = Om

    CollideAndResolve = 1
End Function

'------------------------------------------------------------------------------
' SHUTTER BACKBONE
'------------------------------------------------------------------------------
Function NRNG() As Byte

    Local The_NRNG As Byte

    If Switch_Hex = 0 Then
       ' Hex Mode: 16 unique outputs mapped straight to values 0-15
       Cast_single = MultiRandRange("Noisy", 0 , 15)
    Else
       ' Dice Mode: 6 standard physical die faces [1..6]
       Cast_single = MultiRandRange("Noisy", 1 , 6)
    End If

    The_NRNG = Fix(Cast_single)

    Call PrintLog("<-- N_RNG: " + Str(The_NRNG))

   NRNG = The_NRNG
End Function

'------------------------------------------------------------------------------
' LIGHTWEIGHT JITTER BACKBONE
'------------------------------------------------------------------------------
Function TRNG() As Byte

    Local The_TRNG As Byte

    If Switch_Hex = 0 Then
       ' Hex Mode: 16 unique outputs mapped straight to values 0-15
       Cast_single = MultiRandRange("Truly", 0 , 15)
    Else
       ' Dice Mode: 6 standard physical die faces [1..6]
       Cast_single = MultiRandRange("Truly", 1 , 6)
    End If

    The_TRNG = Fix(Cast_single)

    Call PrintLog("<-- T_RNG: " + Str(The_TRNG))

   TRNG = The_TRNG
End Function


'------------------------------------------------------------------------------
' HEAVY JITTER BACKBONE
'------------------------------------------------------------------------------
Function MRNG() As Byte

    Local The_MRNG As Byte

    If Switch_Hex = 0 Then
       ' Hex Mode: 16 unique outputs mapped straight to values 0-15
       Cast_single = MultiRandRange("Mixy", 0 , 15)
    Else
       ' Dice Mode: 6 standard physical die faces [1..6]
       Cast_single = MultiRandRange("Mixy", 1 , 6)
    End If

    The_MRNG = Fix(Cast_single)

    Call PrintLog("<-- M_RNG: " + Str(The_MRNG))

   MRNG = The_MRNG
End Function

'------------------------------------------------------------------------------
' LIGHTWEIGHT PHYSICS SIMULATION BACKBONE
' Returns only the final top label - no logs, no graphics, no streaming
'------------------------------------------------------------------------------
Function HRNG() As Byte

    ' Clean, one-per-line local allocations to satisfy frame offsets
    Local G_val As Single
    Local Max_time As Single
    Local DT_Temp_factor As Single    ' Environmental Temp Factor -> Reused as Active_dt in Loop
    Local TR_Humid_factor As Single   ' Environmental Humidity Factor -> Reused as Time_remaining in Loop
    Local Base_rest As Single
    Local Base_fric As Single
    Local Base_adh As Single
    Local Base_angle As Single
    Local Init_angle As Single
    Local Init_omega_val As Single
    Local Height_val As Single
    Local Rest_val As Single
    Local Fric_val As Single
    Local Adh_val As Single
    Local Speed_val As Single
    Local S_temp1 As Single
    Local S_temp2 As Single
    Local L_min As Long
    Local L_max As Long
    Local Settled_count As Word
    Local Final_top_g As Byte
    Local Loop_i As Byte
    Local Target_j As Byte
    Local avr_log As String * 4
    Local impact_log As Single

    Local H_Idx As Byte
    Local Look_Ahead As Byte
    Local Look_Kinetic_Step As Byte
    Local Look_Kinetic_Jump As Byte

    ' Physical Cube Dimension Constants
    Const Side_const = 0.05
    Const Mass_const = 0.02
    Const Half_const = 0.025
    Const Inertia_const = 0.000008333

    ' Adaptive Lens Zoom Stepping Velocity Constants
    Const Dt_const_zoom_in_Slow = 0.0005   ' Pristine precision collision steps / default: 0.0005
    Const Dt_const_zoom_in_Fast = 0.0007   ' Pristine precision collision steps / default: 0.0005
    Const Dt_const_zoom_out = 0.001  ' 10x Fast-forward speed steps in mid-air
    Const Rd_to_impact = 0.07
    Const Rt_to_Stop = 1.25

    ' Freeze and lock master timing tracking states
    Droptimerms = I_timer
    Seedfrozen = 1

    Call Manage_led(7 , 0 , 0)

    ' ------------------------------------------------------------
    Call PrintLog("-> Shuffle <-")

    Cast_Single = MultiRandRange("Noisy", 1.0, 4.0)
    Dicemat = Fix(Cast_Single)
    Cast_Single = MultiRandRange("Noisy", 1.0, 6.0)
    Surfmat = Fix(Cast_Single)
    Cast_Single = MultiRandRange("Noisy", 1.0, 4.0)
    Inittop = Fix(Cast_Single)

    Humidity = MultiRandRange("Noisy", 10.0, 90.0)
    Temperature = MultiRandRange("Noisy", -5.0, 45.0)

    Altitude = MultiRandRange("Noisy", 0.0, 36000.0)
    Height = MultiRandRange("Noisy", 0.5, 4.0)
    Initomega = MultiRandRange("Noisy", -20.0, 20.0)
    Simtime = MultiRandRange("Noisy", 5.0, 25.0)

    ' ------------------------------------------------------------
    ' 1. UNBIASED SAMPLING OF FACE LABELS POOL SETUP
    ' ------------------------------------------------------------
    Call PrintLog("-> Face_Pool <-")

    ' Re-zero the global face pool memory buffer entirely before loading data
    For H_Idx = 1 To 17
        Face_pool(H_Idx) = 0
    Next H_Idx

    For H_Idx = 1 To 4
        Facelabelslocal(H_Idx) = 0
    Next H_Idx

    If Switch_Hex = 0 Then
        ' Hex Mode: 16 unique outputs mapped straight to values 0-15
        For Loop_i = 1 To 16
            Target_j = Loop_i - 1
            Face_pool(Loop_i) = Target_j
        Next Loop_i
        Pool_len = 16
    Else
        ' Standard Mode: 6 standard physical die faces [1..6]
        Face_pool(1) = 1 : Face_pool(2) = 2 : Face_pool(3) = 3
        Face_pool(4) = 4 : Face_pool(5) = 5 : Face_pool(6) = 6
        Pool_len = 6
    End If

    ' ==============================================================================
    ' CLOSED-LOOP ZERO-SPREAD EXTRACTION ENGINE (OPTIMIZED PIPELINE)
    ' ==============================================================================
    Temp_pool_len = Pool_len

    For Loop_i = 1 To 4
        ' 1. Select the dynamic target index among 1 to active pool length
        L_min = 1
        L_max = Temp_pool_len

        '' Base_RNG <- dip switch settings
        Cast_Single = MultiRandRange(RND_base, L_min , L_max)
        Waitms 15

        Target_j = Fix(Cast_Single)

        ' 2. MERGED: Directly record the selected item into the destination array
        Facelabelslocal(Loop_i) = Face_pool(Target_j)

        ' 3. SHIFT WINDOW: Pull zeros and trailing data leftward from Target_j to 15
        For H_Idx = Target_j To 16
           Look_Ahead = H_Idx + 1
           Face_pool(H_Idx) = Face_pool(Look_Ahead)
        Next H_Idx

        ' 4. Shrink active virtual bounds, isolating trailing cells out of scope
        Decr Temp_pool_len

        ' 5. Print the log
        If Switch_Export = 0 Then
            Print "Face_pool("; Str(Loop_i); ")"
            For H_Idx = 1 To 17
               Print Str(Face_pool(H_Idx)); "*";
            Next H_Idx

            Print " "
        End If

    Next Loop_i

    ' ------------------------------------------------------------
    ' 2. SYMMETRIC FLOTATION NOISE LAYER VARIATIONS
    ' ------------------------------------------------------------
    Call PrintLog("-> Noise <-")

    noiseAngle = MultiRandRange("Noisy", -0.0261799, 0.0261799)  ''[1.5 * PI / 180]
    noiseRest = MultiRandRange("Noisy", -0.02, 0.02)
    noiseFric = MultiRandRange("Noisy", -0.03, 0.03)
    noiseAdh = MultiRandRange("Noisy", -0.015, 0.015)
    noiseOmega = MultiRandRange("Noisy", -0.8, 0.8)
    noiseHeight = MultiRandRange("Noisy", -0.01, 0.01)
    noiseAlt = MultiRandRange("Noisy", -25.0, 25.0)
    noiseTime = MultiRandRange("Noisy", -1.0, 1.0)

    ' ------------------------------------------------------------
    ' 3. ENVIRONMENTAL COEFFICIENTS CALCULATIONS
    ' ------------------------------------------------------------
    ' Calculate active gravity acceleration vector
    S_temp1 = Altitude + Noisealt
    G_val = GravityAtAltitude(S_temp1)

    ' Evaluate total permissible execution tracking duration
    Max_time = Simtime + Noisetime
    If Max_time < 3.0 Then Max_time = 3.0

    ' Linearly unroll scalar temperature scaling factor parameters
    S_temp1 = Temperature - 20.0
    S_temp2 = S_temp1 * 0.004
    DT_Temp_factor = 1.0 - S_temp2

    ' Linearly unroll scalar humidity scaling factor parameters
    S_temp1 = Humidity - 40.0
    S_temp2 = S_temp1 * 0.006
    TR_Humid_factor = 1.0 + S_temp2

    ' baseRest = 0.5 * (brd + brs) * Math.max(0.6, tempFactor)
    S_temp1 = DICE_MATERIALS(DiceMat , 2)
    S_temp2 = SURFACE_MATERIALS(SurfMat , 2)
    Base_rest = S_temp1 + S_temp2
    Base_rest = 0.5 * Base_rest
    S_temp1 = DT_Temp_factor
    If S_temp1 < 0.6 Then S_temp1 = 0.6
    Base_rest = Base_rest * S_temp1

    ' baseFric = 0.5 * (bfd + bfs) * Math.max(0.5, tempFactor) * Math.min(1.6, humidFactor)
    S_temp1 = DICE_MATERIALS(DiceMat , 1)
    S_temp2 = SURFACE_MATERIALS(SurfMat , 1)
    Base_fric = S_temp1 + S_temp2
    Base_fric = 0.5 * Base_fric
    S_temp1 = DT_Temp_factor
    If S_temp1 < 0.5 Then S_temp1 = 0.5
    Base_fric = Base_fric * S_temp1
    S_temp2 = TR_Humid_factor
    If S_temp2 > 1.6 Then S_temp2 = 1.6
    Base_fric = Base_fric * S_temp2

    ' baseAdh = 0.5 * (bad + bas) * Math.min(2.0, humidFactor)
    S_temp1 = DICE_MATERIALS(DiceMat , 3)
    S_temp2 = SURFACE_MATERIALS(SurfMat , 3)
    Base_adh = S_temp1 + S_temp2
    Base_adh = 0.5 * Base_adh
    S_temp1 = TR_Humid_factor
    If S_temp1 > 2.0 Then S_temp1 = 2.0
    Base_adh = Base_adh * S_temp1

    ' Combine base parameters with active noise variables
    Base_angle = AngleForTopFace(InitTop)
    Init_angle = Base_angle + Noiseangle
    Init_omega_val = Initomega + Noiseomega
    Height_val = Height + Noiseheight

    Rest_val = Base_rest + Noiserest
    If Rest_val < 0.05 Then Rest_val = 0.05
    If Rest_val > 0.95 Then Rest_val = 0.95

    Fric_val = Base_fric + Noisefric
    If Fric_val < 0.05 Then Fric_val = 0.05

    Adh_val = Base_adh + Noiseadh
    If Adh_val < 0.0 Then Adh_val = 0.0

    ' Initialize global state vectors matrix tracking points
    Physics_state(1) = 0.0                             ' state[0] = x
    Physics_state(2) = Height_val                      ' state[1] = y
    Physics_state(3) = Init_angle                      ' state[2] = th
    Physics_state(4) = 0.0                             ' state[3] = vx
    Physics_state(5) = 0.0                             ' state[4] = vy
    Physics_state(6) = Init_omega_val                  ' state[5] = om

    Call Reset_led()

    ' ------------------------------------------------------------
    ' 4. KINEMATIC INTEGRATION & CORE PHYSICS LOOP ENGINE
    ' ------------------------------------------------------------
    Remaining_Sim = 0.0
    Sim_t = 0.0
    Settled_count = 0
    Look_Kinetic_Step = 1
    Look_Kinetic_Jump = 1

    Call PrintLog("-> History <-")

    While Sim_t < Max_time

        ' 1. STATE IDENTIFICATION GENERATION
        Remaining_Sim = Max_time - Rt_to_Stop

        If Sim_t >= Remaining_Sim Then
            Set zoomin_by_time
        Else
            Reset zoomin_by_time
        End If

        If Physics_state(2) <= Rd_to_impact Then
            Set zoomin_by_dist
        Else
            Reset zoomin_by_dist
        End If

        If Physics_state(5) >= 0.0 Then
            Set zoomout_by_pv
        Else
            Reset zoomout_by_pv
        End If

        If Physics_state(4) < 0.0 Then
            Set move_by_lv
        Else
            Reset move_by_lv
        End If

        If Physics_state(4) > 0.0 Then
            Set move_by_rv
        Else
            Reset move_by_rv
        End If

        ' 2. GEOMETRIC & DIRECTIONAL LIGHTWEIGHT SELECTION
        If zoomin_by_time = 1 And zoomin_by_dist = 1 Then
           DT_Temp_factor = Dt_const_zoom_in_Slow
           avr_log = "TD: "
        ElseIf zoomin_by_time = 1 Then
           DT_Temp_factor = Dt_const_zoom_in_Fast
           avr_log = "TX: "
        ElseIf zoomin_by_dist = 1 Then
           DT_Temp_factor = Dt_const_zoom_in_Slow
           avr_log = "XD: "
        Else
           DT_Temp_factor = Dt_const_zoom_out
           H_Idx = 0  ' No collisions can occur while rising or clear of the floor
        End If

        ' Apply Gravitational Pull: state -= G * DT
        S_temp1 = G_val * DT_Temp_factor
        Physics_state(5) = Physics_state(5) - S_temp1

        ' Integrate Linear X Position: state += state * DT
        S_temp1 = Physics_state(4) * DT_Temp_factor
        Physics_state(1) = Physics_state(1) + S_temp1

        ' Integrate Linear Y Position: state += state * DT
        S_temp1 = Physics_state(5) * DT_Temp_factor
        Physics_state(2) = Physics_state(2) + S_temp1

        ' Integrate Angular Orientation: state += state * DT
        S_temp1 = Physics_state(6) * DT_Temp_factor
        Physics_state(3) = Physics_state(3) + S_temp1

        ' Evaluate structural collisions checks safely
        If DT_Temp_factor <> Dt_const_zoom_out Then

            Call PrintHistory("HST_zoom_" + avr_log)
            impact_log = Physics_state(6)

            H_Idx = CollideAndResolve(Rest_val , Fric_val , Adh_val , Mass_const , Inertia_const , Half_const)

            If impact_log <> Physics_state(6) Then
               Call PrintHistory("HST_impact+: ")
            End IF
        End If

        '============================================================
        ' NEW POSITION FOR SPEED CALCULATION (OPTIMIZED)
        '============================================================
        ' We compute this here so both the sleep out check and the
        ' standard settlement counter have access to uncorrupted data.
        S_temp1 = Physics_state(4) * Physics_state(4)
        S_temp2 = Physics_state(5) * Physics_state(5)
        S_temp1 = S_temp1 + S_temp2
        S_temp1 = Sqr(S_temp1)

        S_temp2 = Abs(Physics_state(6))
        S_temp2 = S_temp2 * Side_const
        Speed_val = S_temp1 + S_temp2

        '============================================================
        ' UPGRADED V1.2 HYBRID SLEEP OUT CHECK
        '============================================================
        ' 0.026 = Microscopic floor boundary (less than 1mm elevation)
        ' If the die is on the floor and total kinetic energy (including
        ' horizontal/angular friction crawl) falls below 0.05, put it to sleep!
        ''If Physics_state(2) < 0.026 Then
        ''   If Speed_val < 0.05 Then
        ''      Exit While
        ''   End If
        ''End If
        ' UPGRADED V1.3 HYBRID SLEEP OUT CHECK
        If Physics_state(2) < 0.05 Then
           If Speed_val < 0.075 Then

            If Switch_Export = 0 Then
               Print "HST_trigger: [sleep_out] / [speed] "; Speed_val ; " < 0.075 / [Y] "; Physics_state(2) ; " < 0.05"
            End IF

            Call PrintHistory("HST_sleep_out: ")

            Exit While
           End If
        End If

        '============================================================
        ' Settlement Criteria Evaluation Check (Standard Mode Fallback)
        '============================================================
        ' Evaluate relative ground proximity boundaries limits
        S_temp1 = Half_const + 0.0005
        If Physics_state(2) < S_temp1 And Speed_val < 0.2 Then
            Incr Settled_count

            If Switch_Export = 0 Then
               Print "HST_trigger: [settled "; Settled_count ; " < 100] / [speed] "; Speed_val ; " < 0.2 / [Y] "; Physics_state(2) ; " < "; S_temp1
            End IF

            ' Break iteration bounds if stable for 100 consecutive frames
            If Settled_count > 70 Then
              Call PrintHistory("HST_settled: ")

               Exit While
            End If
        Else
            Settled_count = 0
        End If

        ' ------------------------------------------------------------
        ' Diagnostic Monitoring LED Drive
        ' ------------------------------------------------------------
        If Look_Kinetic_Step = 1 Then
           Call Manage_led(1 , 0 , Look_Kinetic_Jump)
        End If

        If Look_Kinetic_Step = 1 And DT_Temp_factor = Dt_const_zoom_out Then
           Call PrintHistory("HST_zoom_out: ")
        End If

        Incr Look_Kinetic_Step

        If Look_Kinetic_Step = 51 Then
           Look_Kinetic_Step = 1
           Look_Kinetic_Jump = 1 - Look_Kinetic_Jump
        End If

        Call Manage_led(0 , 0 , Not zoomout_by_pv)
        Call Manage_led(4 , 0 , Not zoomin_by_dist)
        Call Manage_led(7 , 0 , Not zoomin_by_time)

        Call Manage_led(5 , 0 , Not move_by_lv)
        Call Manage_led(3 , 0 , Not move_by_rv)

        ' Step simulation time counter forward dynamically
        Sim_t = Sim_t + DT_Temp_factor

    Wend

    If Sim_t >= Max_time Then
       Call PrintHistory("HST_time_out: ")
    End If

    ' ------------------------------------------------------------
    ' 5. EXTRACT TARGET LANDING FACE IDENTIFIER
    ' ------------------------------------------------------------
    Final_top_g = FaceFromAngle(Physics_state(3) , "top")

    ' Correct matching offset: map internal orientation code [0..3] into array indices [1..4]
    Incr Final_top_g

    Call PrintLog("<-- H_RNG: " + Str(Facelabelslocal(Final_top_g)))
    Call SendSessionJson()

    ' Return final selected top face label code cleanly
    HRNG = Facelabelslocal(Final_top_g)
End Function


'------------------------------------------------------------------------------
Sub PrintLog(ByVal Msg As String * 20)

    If Switch_Export = 0 Then
       Print Msg
    End If

End Sub

'------------------------------------------------------------------------------
Sub PrintEntropy(Byval isStreaming As Byte)

   Call Reset_led()
   Call Manage_led(2 , 0 , Not Current_nibbles.3)
   Call Manage_led(3 , 0 , Not Current_nibbles.2)
   Call Manage_led(6 , 0 , Not Current_nibbles.1)
   Call Manage_led(5 , 0 , Not Current_nibbles.0)

   If Switch_Export = 0 Or isStreaming = 1 Then
      ' --------------------------------------------------------------
      ' 3. ASCII SERIAL PERIPHERAL STREAMING (Out via PD.1 TX)
      ' Using clean BASCOM single-line conditional print format
      ' --------------------------------------------------------------
      If Current_nibbles.3 = 1 Then Print "1"; Else Print "0";
      If Current_nibbles.2 = 1 Then Print "1"; Else Print "0";
      If Current_nibbles.1 = 1 Then Print "1"; Else Print "0";
      If Current_nibbles.0 = 1 Then Print "1"; Else Print "0";
      ' --------------------------------------------------------------
   End If

End Sub

'------------------------------------------------------------------------------
Sub PrintJitter(Byval isStreaming As Byte)
   Local I As Byte

   If Switch_Export = 0 Or isStreaming = 1 Then

      For I = 1 To 32
          Print Str(Block_J2(I)); "~";
      Next I

      For I = 1 To 32
          Print Str(Block_J3(I)); "^";
      Next I

   End If

End Sub

'------------------------------------------------------------------------------
Sub PrintHistory(ByVal Msg As String * 20)

    If Switch_Export = 0 Then
       Print Msg; Str(Sim_t); ","; Physics_state(1); ","; Physics_state(2); ","; Physics_state(3); ","; Physics_state(4); ","; Physics_state(5); ","; Physics_state(6)
    End If

End Sub


'==============================================================================
' FIXED: HIGH-SPEED ENTROPY ACCUMULATOR BIT-PRINTER
' Uses mathematical MSB masking to completely bypass byte-indexing bugs
'==============================================================================
Sub PrintValBits(ByVal Target_Acc As DWord, ByVal Msg as String * 20)

   Local Bit_Idx As Byte
   Local PRN_Acc As DWord

   If Switch_Export = 0 Then

      PRN_Acc = Target_Acc

      Print "   ["; Msg; "] ";

      For Bit_Idx = 1 To 32

          ' 1. Check if the absolute highest bit (Bit 31) is active
          ' If a 32-bit unsigned word is >= &H80000000, its MSB is guaranteed to be 1
          If Target_Acc >= &H80000000 Then
             Print "1";
          Else
             Print "0";
          End If

          ' 2. Shift the entire accumulator left by 1 bit to bring the next bit to the MSB position
          Shift Target_Acc , Left , 1

      Next Bit_Idx

      ' Print a new line only after the full 32-bit block is finished
      Print " <- ";
      Print Str(PRN_Acc)

   End If

End Sub


'==============================================================================
' EXPORT SESSION SUBSYSTEM (Clean Single-Quote JSON Formatter)
'==============================================================================
Sub SendSessionJson()
    ''Local T_drop_ms As Long
    Local Hex_Char_Str As String * 2
    Local F_val As Byte
    Local Loop_idx As Byte
    Local Q As String * 1

    If Switch_Export <> 0 Then
      Exit Sub
    End If

    ' Define a handy quote constant character to prevent double-quote clutter
    Q = Chr(34)

    ' Convert drop timer single/float to long integer milliseconds
    ''T_drop_ms = FloatToLong32(Droptimerms)

    Print "{"
    Print "  " ; Q ; "version" ; Q ; ": 3,"
    Print "  " ; Q ; "timestamp" ; Q ; ": " ; Q ; "2026-09-25T12:00:00.000Z" ; Q ; ","

    ' Fingerprints the exact mathematical execution engine of the core chip
    Print "  " ; Q ; "simulatorProfile" ; Q ; ": " ; Q ; "AVR_BASCOM_32BIT" ; Q ; ","
    Print "  " ; Q ; "exactSession" ; Q ; ": true,"
    Print "  " ; Q ; "dropTimerMs" ; Q ; ": " ; Droptimerms ; ","

    ' labelMode format mapping
    If Switch_Hex = 0 Then
        Print "  " ; Q ; "labelMode" ; Q ; ": " ; Q ; "hex" ; Q ; ","
    Else
        Print "  " ; Q ; "labelMode" ; Q ; ": " ; Q ; "dice" ; Q ; ","
    End If

    ' faceLabels array with Hex character mapping (0-15 -> '0'-'f')
    Print "  " ; Q ; "faceLabels" ; Q ; ": ["
    For Loop_idx = 1 To 4
        F_val = Facelabelslocal(Loop_idx)
        If F_val < 10 Then
            Hex_Char_Str = Str(F_val)
        Else
            Select Case F_val
                Case 10 : Hex_Char_Str = "a"
                Case 11 : Hex_Char_Str = "b"
                Case 12 : Hex_Char_Str = "c"
                Case 13 : Hex_Char_Str = "d"
                Case 14 : Hex_Char_Str = "e"
                Case 15 : Hex_Char_Str = "f"
                Case Else : Hex_Char_Str = "0"
            End Select
        End If

        If Loop_idx < 4 Then
            Print "    " ; Q ; Hex_Char_Str ; Q ; ","
        Else
            Print "    " ; Q ; Hex_Char_Str ; Q
        End If
    Next
    Print "  ],"

    ' Noise parameter floating-point outputs
    Print "  " ; Q ; "noiseAngle" ; Q ; ": " ; Noiseangle ; ","
    Print "  " ; Q ; "noiseOmega" ; Q ; ": " ; Noiseomega ; ","
    Print "  " ; Q ; "noiseHeight" ; Q ; ": " ; Noiseheight ; ","
    Print "  " ; Q ; "noiseRest" ; Q ; ": " ; Noiserest ; ","
    Print "  " ; Q ; "noiseFric" ; Q ; ": " ; Noisefric ; ","
    Print "  " ; Q ; "noiseAdh" ; Q ; ": " ; Noiseadh ; ","
    Print "  " ; Q ; "noiseAlt" ; Q ; ": " ; Noisealt ; ","
    Print "  " ; Q ; "noiseTime" ; Q ; ": " ; Noisetime ; ","

    ' Dice Material String Mapping
    Print "  " ; Q ; "diceMat" ; Q ; ": " ;
    Select Case Dicemat
        Case 1 : Print Q ; "plastic" ; Q ; ","
        Case 2 : Print Q ; "wood" ; Q ; ","
        Case 3 : Print Q ; "metal" ; Q ; ","
        Case 4 : Print Q ; "rubber" ; Q ; ","
        Case Else : Print Q ; "rubber" ; Q ; ","
    End Select

    ' Surface Material String Mapping
    Print "  " ; Q ; "surfMat" ; Q ; ": " ;
    Select Case Surfmat
        Case 1 : Print Q ; "wood" ; Q ; ","
        Case 2 : Print Q ; "carpet" ; Q ; ","
        Case 3 : Print Q ; "glass" ; Q ; ","
        Case 4 : Print Q ; "metal" ; Q ; ","
        Case 5 : Print Q ; "rubber" ; Q ; ","
        Case 6 : Print Q ; "felt" ; Q ; ","
        Case Else : Print Q ; "glass" ; Q ; ","
    End Select

    ' Environmental & Physics Parameters (Ensuring variables are accessed properly)
    Print "  " ; Q ; "temperature" ; Q ; ": " ; Temperature ; ","
    Print "  " ; Q ; "humidity" ; Q ; ": " ; Humidity ; ","
    Print "  " ; Q ; "altitude" ; Q ; ": " ; Altitude ; ","
    Print "  " ; Q ; "height" ; Q ; ": " ; Height ; ","
    Print "  " ; Q ; "initOmega" ; Q ; ": " ; Initomega ; ","
    Print "  " ; Q ; "initTop" ; Q ; ": " ; Inittop ; ","
    Print "  " ; Q ; "simTime" ; Q ; ": " ; Simtime ; ","
    Print "  " ; Q ; "showAnim" ; Q ; ": true"
    Print "}"

    Waitms 300
End Sub

'------------------------------------------------------------------------------
Sub Manage_led(ByVal The_7seg As Byte , ByVal The_milisec As Integer , ByVal The_state As Byte)
   If The_7seg = 1 Then
      Flag_7seg_a = The_state
   ElseIf The_7seg = 2 Then
      Flag_7seg_b = The_state
   ElseIf The_7seg = 3 Then
      Flag_7seg_c = The_state
   ElseIf The_7seg = 4 Then
      Flag_7seg_d = The_state
   ElseIf The_7seg = 5 Then
      Flag_7seg_e = The_state
   ElseIf The_7seg = 6 Then
      Flag_7seg_f = The_state
   ElseIf The_7seg = 7 Then
      Flag_7seg_g = The_state
   ElseIf The_7seg = 0 Then
      Flag_7seg_dp = The_state
   End If
   If The_milisec > 0 Then Waitms The_milisec
End Sub

'------------------------------------------------------------------------------
Sub ShowHexOn7Seg(ByVal HexVal As Byte , ByVal IsCommonAnode As Byte)

    Local Pattern As Byte

    If HexVal = 17 Then Return '' this is a self audit procedure..
    Pattern = SegMap(HexVal + 1)
    If IsCommonAnode = 1 Then Pattern = Not Pattern

    Call Manage_led(1 , 0 , Pattern.0)
    Call Manage_led(2 , 0 , Pattern.1)
    Call Manage_led(3 , 0 , Pattern.2)
    Call Manage_led(4 , 0 , Pattern.3)
    Call Manage_led(5 , 0 , Pattern.4)
    Call Manage_led(6 , 0 , Pattern.5)
    Call Manage_led(7 , 0 , Pattern.6)

End Sub

'==============================================================================
' HEARTBIT TIMER INTERRUPT SERVICE ROUTINE
'==============================================================================
Ticktok:
   Timer0 = 131
   I_timer = I_timer + 1
   If I_timer > 2000000000 Then
      I_timer = 0
   End If
Return

'==============================================================================
' UART RECEIVE INTERRUPT SERVICE ROUTINE
'==============================================================================
Isr_Serial_Rx:
    ' Read the incoming byte from the UART hardware register
    'Incoming_Char = UDR0
    Incoming_Char = Inkey()

    ''Print "-> InKey: "; Str(Incoming_Char); " <-"

    If Incoming_Char >= 48 And Incoming_Char <= 56 Then

      ' 0 = STOP STREAMING    <-- 48
      ' 1 = SHUTTER STREAMING MODE
      ' 2 = JITTER STREAMING MODE
      ' 3 = NRNG
      ' 4 = TRNG
      ' 5 = MRNG
      ' 6 = HRNG - Noisy
      ' 7 = HRNG - Truly
      ' 8 = HRNG - Mixy

      Current_streaming = Incoming_Char - 48
      Print "-> Stream: "; Str(Current_streaming); " <-"

    End If

Return

'==============================================================================
' TIMING JITTER 2, INTERRUPT SERVICE ROUTINE
'==============================================================================
Isr_int0:

    If Block_J2_Index < 32 Then
       Now_J2 = Timer1
       Delta_J2 = Now_J2 - Last_J2
       Last_J2 = Now_J2

       ' Append to block
       Incr Block_J2_Index
       Block_J2(Block_J2_Index) = Delta_J2
    Else
       Disable Int0
    End If

Return

'==============================================================================
' TIMING JITTER 3, INTERRUPT SERVICE ROUTINE
'==============================================================================
Isr_int1:

    If Block_J3_Index < 32 Then
       Now_J3 = Timer1
       Delta_J3 = Now_J3 - Last_J3
       Last_J3 = Now_J3

       ' Append to block
       Incr Block_J3_Index
       Block_J3(Block_J3_Index) = Delta_J3
    Else
       Disable Int1
    End If

Return