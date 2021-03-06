RazorMargin = 600

macro search RootNode, PvNode
	; in:
	;  rbp:	address	of Pos struct in thread	struct
	;  rbx:	address	of State
	;  ecx:	alpha
	;  edx:	beta
	;  r8d:	depth
	;  r9l:	cutNode	 must be 0 or -1 (=FFh)
	; out:
	;  eax:	score
  if RootNode =	1 & PvNode = 0
    err	'bad params to search'
  end if

  virtual at rsp
    .tte		rq 1
    .ltte		rq 1
    .posKey		rq 1
    .ttMove		rd 1
    .ttValue		rd 1
    .move		rd 1
    .excludedMove	rd 1
    .bestMove		rd 1
    .ext		rd 1
    .newDepth		rd 1
    .predictedDepth	rd 1
    .moveCount		rd 1
    .quietCount		rd 1
    .captureCount	rd 1
    .alpha		rd 1
    .beta		rd 1
    .depth		rd 1
	.statBonusDepth  rd 1
    .bestValue		rd 1
    .value		rd 1
    .evalu		rd 1
    .pureStaticEval		rd 1
    .nullValue		rd 1
    .futilityValue	rd 1
    .extension		rd 1
    .success		rd 1	; for tb
    .rbeta		rd 1
	.probCutCount	rd 1
    .moved_piece_to_sq	rd 1
    .reductionOffset	rd 1
    .skipQuiets		    rb 1    ; -1 for true
    .singularExtensionNode  rb 1
    .improving		    rb 1
    .captureOrPromotion	    rb 1    ; nonzero for true
    .doFullDepthSearch	    rb 1
    .cutNode		    rb 1    ; -1 for true
    .ttHit		    rb 1
    .moveCountPruning	    rb 1    ; -1 for true
    .ttCapture		    rd 1    ; 1	for true
    .reduction		    rd 1
    .quietsSearched	rd 64
    .capturesSearched	rd 32
    if PvNode =	1
      .pvExact		rd 1
      .pv		rd MAX_PLY + 1
    end	if
    .lend		rb 0
  end virtual
  .localsize = (.lend-rsp+15) and -16

	       push   rbx rsi rdi r12 r13 r14 r15
	 _chkstk_ms   rsp, .localsize
		sub   rsp, .localsize

		mov   dword[.alpha], ecx
		mov   dword[.beta], edx
		mov   dword[.depth], r8d
		mov   byte[.cutNode], r9l
  if DEBUG
		lea   eax, [r9+1]
	     Assert   b, al, 2,	'assertion .cutNode == 0 or -1 failed in Search'
  end if

  if RootNode = 1
             Assert   e, byte[rbx+State.ply], 0, 'assertion ss->ply == 0 failed in SearchRoot'
  end if

Display	2, "Search(alpha=%i1, beta=%i2, depth=%i8) called%n"
 if RootNode = 0
		cmp   ecx, VALUE_DRAW
		jge   @1f

		mov   dx, word[rbx+State.rule50]
		cmp   dx, 3
		jl    @1f

		movzx r12d, byte[rbx + State.ply]
		call  Position_HasGameCycle
		cmp   eax, 1
		jne   @1f

 if PvNode = 1
		value_draw  rax, dword[.depth], qword[rbp-Thread.rootPos+Thread.nodes]
		cmp   eax, dword[.beta]
		mov   dword[.alpha], eax
		jl   @1f
else
		value_draw  rax, dword[.depth], qword[rbp-Thread.rootPos+Thread.nodes]
		cmp   eax, dword[.beta]
		jl   @2f
end if

		jmp .Return
@2:
		mov   dword[.alpha], eax
@1:
end if

		mov   r8d, dword[.depth]
		cmp   r8d, 1
		jge   .skipdownto_step1

if PvNode = 1
		mov   rcx, qword[rbx+State.checkersBB]
		test  rcx, rcx
		jz  .S0_pv_noCheck

		lea   r12, [QSearch_Pv_InCheck]
		mov   ecx,  dword[.alpha]
		mov   edx,  dword[.beta]
		xor   r8d, r8d
		call   r12
		jmp .Return

.S0_pv_noCheck:
		lea   r12, [QSearch_Pv_NoCheck]
		mov   ecx,  dword[.alpha]
		mov   edx,  dword[.beta]
		xor   r8d, r8d
		call   r12
		jmp .Return

else
		mov   rcx, qword[rbx+State.checkersBB]
		test  rcx, rcx
		jz  .S0_nonpv_noCheck

		lea   r12, [QSearch_NonPv_InCheck]
		mov   ecx,  dword[.alpha]
		mov   edx,  dword[.beta]
		xor   r8d, r8d
		call   r12
		jmp .Return

.S0_nonpv_noCheck:
		lea   r12, [QSearch_NonPv_NoCheck]
		mov   ecx,  dword[.alpha]
		mov   edx,  dword[.beta]
		xor   r8d, r8d
		call   r12
		jmp .Return
end if

.skipdownto_step1:
	; Step 1. initialize node
		xor   eax, eax
		mov   dword[.moveCount], eax
		mov   dword[.quietCount], eax
		mov   dword[.captureCount], eax
		mov   dword[rbx+State.moveCount], eax
		mov   dword[.bestValue], -VALUE_INFINITE

	      movzx   r12d, byte[rbx + State.ply]
		lea   edx, [r12 + 1]
	        mov   byte[rbx + 1*sizeof.State + State.ply], dl
        ; edx = ss->ply + 1  ( = (ss + 1)->ply )
        ; r12d = ss->ply

  if PvNode = 1
	      movzx   eax, byte[rbp-Thread.rootPos+Thread.selDepth]
		cmp   eax, edx
	      cmovb   eax, edx
		mov   byte[rbp-Thread.rootPos+Thread.selDepth],	al
  end if

	; callsCnt counts down as in master
	; resetCnt, if nonzero,	contains the count to which callsCnt should be reset
		mov   eax, dword[rbp-Thread.rootPos+Thread.resetCnt]
		mov   edx, dword[rbp-Thread.rootPos+Thread.callsCnt]
	       test   eax, eax
		 jz   .dontreset
		mov   edx, eax
		mov   dword[rbp-Thread.rootPos+Thread.resetCnt], 0
	.dontreset:
		sub   edx, 1
		mov   dword[rbp-Thread.rootPos+Thread.callsCnt], edx
		jns   .dontchecktime
	       call   CheckTime		; CheckTime sets resetCalls for	all threads
	.dontchecktime:


  if RootNode =	0
	; Step 2. check	for aborted search and immediate draws
	      movzx   edx, word[rbx+State.rule50]
	      movzx   ecx, word[rbx+State.pliesFromNull]
		mov   r8, qword[rbx+State.key]
		mov   eax, r12d
		cmp   r12d, MAX_PLY
		jae   .AbortSearch_PlyBigger
		cmp   byte[signals.stop], 0
		jne   .AbortSearch_PlySmaller

	; ss->ply < MAX_PLY holds at this point, so if we should
	;   go to .AbortSearch_PlySmaller if a draw is detected
	  PosIsDraw   .AbortSearch_PlySmaller, .CheckDraw_Cold,	.CheckDraw_ColdRet


	; Step 3. mate distance	pruning
		mov   ecx, dword[.alpha]
		mov   edx, dword[.beta]
		mov   eax, r12d
		sub   eax, VALUE_MATE
		cmp   ecx, eax
	      cmovl   ecx, eax
		not   eax
		cmp   edx, eax
	      cmovg   edx, eax
		mov   dword[.alpha], ecx
		mov   dword[.beta], edx
		mov   eax, ecx
		cmp   ecx, edx
		jge   .Return
  end if

             Assert   b, r12d, MAX_PLY, 'assertion 0 <= ss->ply < MAX_PLY failed in Search'

		xor   eax, eax
		mov   ecx, CmhDeadOffset
		add   rcx, qword[rbp+Pos.counterMoveHistory]
		mov   dword[.bestMove],	eax
		mov   dword[rbx+1*sizeof.State+State.excludedMove], eax
		mov   dword[rbx+0*sizeof.State+State.currentMove], eax
		mov   qword[rbx+0*sizeof.State+State.counterMoves], rcx
		mov   qword[rbx+2*sizeof.State+State.killers], rax
		mov   dword[rbx + 2*sizeof.State + State.statScore], eax

  if USE_SYZYGY	& RootNode = 0
	; get a	count of the piece for tb
		mov   rax, qword[rbp+Pos.typeBB+8*White]
		 or   rax, qword[rbp+Pos.typeBB+8*Black]
	    _popcnt   rax, rax,	rdx
		mov   r15d, dword[Tablebase_Cardinality]
		sub   r15d, eax
	      movzx   eax, word[rbx+State.rule50]
	      movzx   ecx, byte[rbx+State.castlingRights]
		 or   eax, ecx
		neg   eax
		 or   r15d, eax
	; if r15d <0, don't do tb probe
  end if


	; Step 4. transposition	table look up
		mov   ecx, dword[rbx+State.excludedMove]
		mov   dword[.excludedMove], ecx
                shl   ecx, 16
             movsxd   rcx, ecx
		xor   rcx, qword[rbx+State.key]
		mov   qword[.posKey], rcx

	       call   MainHash_Probe
		mov   qword[.tte], rax
		mov   qword[.ltte], rcx
		mov   byte[.ttHit], dl
		mov   rdi, rcx
		sar   rdi, 48
	      movsx   eax, ch
		mov   r13d, edx
  if RootNode =	0
		shr   ecx, 16
  else
	       imul   ecx, dword[rbp-Thread.rootPos+Thread.PVIdx], sizeof.RootMove
		add   rcx, qword[rbp+Pos.rootMovesVec+RootMovesVec.table]
		mov   ecx, dword[rcx+RootMove.pv+4*0]
  end if
		mov   dword[.ttMove], ecx

		lea   r8d, [rdi+VALUE_MATE_IN_MAX_PLY]
	       test   edx, edx
		 jz   .DontReturnTTValue

		cmp   edi, VALUE_NONE
		 je   .DontReturnTTValue
		cmp   r8d, 2*VALUE_MATE_IN_MAX_PLY
		jae   .ValueFromTT
.ValueFromTTRet:

  if PvNode = 0
		cmp   eax, dword[.depth]
		 jl   .DontReturnTTValue
		mov   eax, BOUND_UPPER
		mov   r8d, BOUND_LOWER
		cmp   edi, dword[.beta]
	     cmovge   eax, r8d
	       test   al, byte[.ltte+MainHashEntry.genBound]
		jnz   .ReturnTTValue
  end if

.DontReturnTTValue:
		mov   dword[.ttValue], edi


  if USE_SYZYGY	& RootNode = 0
    ; Step 5. Tablebase probe
	       test   r15d, r15d
		jns   .CheckTablebase
.CheckTablebaseReturn:
  end if

    ; step 6. evaluate the position statically
		mov   eax, VALUE_NONE
		mov   dword [.evalu], eax
		mov   dword[rbx+State.staticEval], eax
		mov   dword[.pureStaticEval], eax
		mov   rcx, qword[rbx+State.checkersBB]
		mov   byte[.improving],	0
		test   rcx, rcx
		jnz   .moves_loop
		mov   edx, dword[rbx-1*sizeof.State+State.currentMove]
		movsx   eax, word[.ltte+MainHashEntry.eval_]
		test   r13d, r13d ; if (ttHit)
		jnz   .StaticValueYesTTHit

.StaticValueNoTTHit:
		mov   eax, dword[rbx-1*sizeof.State+State.staticEval]
		neg   eax
		add   eax, 2*Eval_Tempo
		mov   r12, qword[.tte]
		cmp   edx, MOVE_NULL
		je   @1f
		call   Evaluate
		mov  r11d, dword[rbx-1*sizeof.State+State.statScore]
		; r11d = p = (ss-1)->statScore
		test r11d, r11d
		jle  @1f
		mov  edx, r11d
		neg  edx
		sub  edx, 2500
		lea  r8d, [rdx + 511]
		test  edx, edx
		cmovs  edx, r8d
		sar  edx, 9
		jmp  @2f

	@1:
		test  r11d, r11d
		mov  edx, 0
		jns  @2f

		mov  edx, r11d
		neg  edx
		add  edx, 2500
		lea  r9d, [rdx + 511]
		test  edx, edx
		cmovs  edx, r9d
		sar  edx, 9

	@2:
		mov  dword[.pureStaticEval], eax
		add  eax, edx
		mov   dword[rbx+State.staticEval], eax
		mov   dword[.evalu], eax
		mov   r9, qword [.posKey]
		shr   r9, 48
		mov   edx, VALUE_NONE
      MainHash_Save   .ltte, r12, r9w, edx, BOUND_NONE,	DEPTH_NONE, 0, word[.pureStaticEval]
		jmp   .StaticValueDone

.StaticValueYesTTHit:
; Structure:
		; else if (ttHit)
				; If_1a
				; If_2a && (If_2b & If_2c)

; else if (ttHit)
  .If_1a:
		cmp   eax, VALUE_NONE ; eax = word[.ltte+MainHashEntry.eval_] = tte->eval()
		jne   @f
		call   Evaluate
   @@:
		xor   ecx, ecx
		mov   dword[.pureStaticEval], eax
		mov   dword[rbx+State.staticEval], eax

  .If_2c:
		cmp   edi, eax
		setg   cl
		add   ecx, BOUND_UPPER
		cmp   edi, VALUE_NONE
		je   .If_1a_ctd

  .If_2b:
		test   cl, byte[.ltte+MainHashEntry.genBound]
		cmovnz   eax, edi ; eval = ttValue;

  .If_1a_ctd:
		mov   dword[.evalu], eax ; eval = ss->staticEval = evaluate(pos)

.StaticValueDone:
		; Step 7. Razoring (skipped when in check)
		mov  edx, dword[.depth]
		cmp  edx, 1*ONE_PLY
		jg   .7skip
	if USE_MATEFINDER = 1
		lea  eax, [rcx+2*VALUE_KNOWN_WIN-1]
		cmp  eax, 4*VALUE_KNOWN_WIN-1
		jae  .7skip
	end if
		mov  ecx, dword[.alpha]
		lea  eax, [ecx - RazorMargin]
		cmp  eax, dword[.evalu]
		jl  .7skip
		mov  edx, dword[.beta]
		xor  r8d, r8d
		if PvNode = 0
			call  QSearch_NonPv_NoCheck
		else
			call  QSearch_Pv_NoCheck
		end if
		jmp  .Return
.7skip:
		mov   edx, dword[rbx-0*sizeof.State+State.staticEval]
		mov   ecx, dword[rbx-2*sizeof.State+State.staticEval]
		cmp   edx, ecx
		setge   al
		cmp   edx, VALUE_NONE
		sete   dl
		cmp   ecx, VALUE_NONE
		sete   cl
		or   al, dl
		or   al, cl
		Assert   b, al, 2,	'assertion al<2	in Search failed'
		mov   byte[.improving],	al   ; should be 0 or 1

		; Step 8. Futility pruning:	child node (skipped when in check)
  if (PvNode = 0 & USE_MATEFINDER = 0) | (PvNode = 0 & USE_MATEFINDER	= 1)
		mov   edx, dword[.depth]
		mov   ecx, dword[rbp+Pos.sideToMove]
		cmp   edx, 7*ONE_PLY
		jge   ._7skip

		mov   al, byte[.improving]
		mov   r8d, -175
		cmp   al, 1
		jne    @f
		mov    r8d, -125
@@:
		imul  edx, r8d
		mov   eax, dword[.evalu]
		cmp   eax, VALUE_KNOWN_WIN
		jge   ._7skip
		add   edx, eax
		cmp   edx, dword[.beta]
		jl   ._7skip
    if USE_MATEFINDER =	0
	      movzx   ecx, word[rbx+State.npMaterial+2*rcx]
	       test   ecx, ecx
		jnz   .Return
    else
		mov   ecx, dword[rbx+State.npMaterial]
	       test   ecx, 0x0FFFF
		 jz   ._7skip
		shr   ecx, 16
		jnz   .Return
    end	if
		jge  .Return
._7skip:
  end if



	; Step 9. Null move search with verification search (is omitted in PV nodes)
  if PvNode = 0
		mov  edx, dword[rbx-1*sizeof.State+State.statScore]
		cmp  edx, 23200
		jge  .8skip
		mov   edx, dword[rbx-1*sizeof.State+State.currentMove]
		cmp   edx, MOVE_NULL
		je  .8skip
		mov   edx, dword[.depth]
		imul   eax, edx,	36
		add   eax, dword[.pureStaticEval]
		mov   esi, dword[.beta]
		cmp   esi, dword[.evalu]
		jg   .8skip
		add   esi, 225
		mov   r8d, dword[.excludedMove]
		test  r8d, r8d
		jnz   .8skip
		xor   rcx,rcx
		mov   ecx, dword[rbp+Pos.sideToMove]
		movzx   ecx, word[rbx+State.npMaterial+2*rcx]
		test   ecx, ecx
		jz   .8skip
    if USE_MATEFINDER =	0
                mov   ecx, dword[rbx + State.ply]
                cmp   ecx, dword[rbp - Thread.rootPos + Thread.nmp_ply]
                jge   @1f
                and   ecx, 1
                cmp   ecx, dword[rbp - Thread.rootPos + Thread.nmp_odd]
                 je   .8skip
        @1:
    else
		mov   r8d, dword[.evalu]
		mov   ecx, dword[rbx+State.npMaterial]
		test   ecx, 0x0FFFF
		 jz   .8skip
		shr   ecx, 16
		 jz   .8skip
		add   r8d, 2*VALUE_KNOWN_WIN-1
		cmp   r8d, 4*VALUE_KNOWN_WIN-1
		jae   .8skip
    end	if
		cmp   eax, esi
		 jl   .8skip

    if USE_MATEFINDER =	1
		mov   edx, dword[.depth]
		cmp   edx, 4
		jbe   .8do
		sub   rsp, MAX_MOVES*sizeof.ExtMove
		mov   rdi, rsp
		call   Gen_Legal
		xor   ecx, ecx
		xor   eax, eax
		mov   rdx, rsp
		cmp   rdx, rdi
		jae   .8loopdone
    .8loop:
		mov   r8d, [rdx+ExtMove.move]
		shr   r8d, 6
		and   r8d, 63
		cmp   byte[rbp+Pos.board+r8], King
		sete  r8b
		add   ecx, r8d
		add   rdx, sizeof.ExtMove
		add   eax, 1
		cmp   rdx, rdi
		jb   .8loop
    .8loopdone:
		add   rsp, MAX_MOVES*sizeof.ExtMove
		test   ecx, ecx
		 jz   .8skip
		cmp   eax, 6
		 jb   .8skip
    end	if

.8do:
		mov   eax, CmhDeadOffset
		add   rax, qword[rbp+Pos.counterMoveHistory]
		mov   dword[rbx+State.currentMove], MOVE_NULL
		mov   qword[rbx+State.counterMoves], rax

		mov   eax, dword[.evalu]
		sub   eax, dword[.beta]
		mov   ecx, 200
		xor   edx, edx
		idiv  ecx
		mov   ecx, 3
		cmp   eax, ecx
		cmovg eax, ecx
		imul  ecx, dword[.depth], 67
		add   ecx, 823
		sar   ecx, 8
		add   eax, ecx

		Assert   ge, eax, 0, 'assertion eax >= 0 failed in	Search'

		mov   esi, dword[.depth]
		sub   esi, eax
	; esi = depth-R

		call   Move_DoNull
		mov   r8d, esi
		lea   r12, [Search_NonPv]
		mov   ecx, dword[.beta]
		neg   ecx
		lea   edx, [rcx+1]
		movzx   r9d, byte[.cutNode]
		not   r9d		; not used in qsearch case
		call   r12
		neg   eax
		xor   dword[rbp+Pos.sideToMove], 1	  ;undo	null move
		sub   rbx, sizeof.State			  ;

		mov   edx, dword[.beta]
		cmp   eax, edx
		 jl   .8skip

		cmp   eax, VALUE_MATE_IN_MAX_PLY
	     cmovge   eax, edx
		mov   edi, eax
	; edi = nullValue

		cmp   dword[rbp - Thread.rootPos + Thread.nmp_ply], 0
		jne   .Return
		lea   ecx, [rdx+VALUE_KNOWN_WIN-1]
		cmp   ecx, 2*(VALUE_KNOWN_WIN-1)
		 ja   .8check

		mov   ecx, dword[.depth]
		cmp   ecx, 12*ONE_PLY
		 jl   .Return
.8check:
		lea   eax, [3*rsi]
		lea   r8d, [rax + 3]
		test  esi, esi
		cmovs eax, r8d
		sar   eax, 2    ; eax = 3 * (depth-R) / 4
		mov   ecx, dword[rbx + State.ply]
		add   eax, ecx
		and   ecx, 1
		mov   dword[rbp - Thread.rootPos + Thread.nmp_ply], eax
		mov   dword[rbp - Thread.rootPos + Thread.nmp_odd], ecx

		mov   r8d, esi
		lea   r12, [Search_NonPv]
		lea   ecx, [rdx-1]
		xor   r9d, r9d
			;  ecx:	alpha
			;  edx:	beta
			;  r8d:	depth
			;  r9l:	cutNode must be 0 or -1 (=FFh)
		call   r12
		xor  ecx, ecx
		mov  qword[rbp - Thread.rootPos + Thread.nmp_ply], rcx
		cmp   eax, dword[.beta]
		mov   eax, edi
		jge   .Return
.8skip:
  end if


	; Step 10. ProbCut (skipped when	in check)
  if PvNode = 0
		mov   eax, dword[.depth]
		cmp   eax, 5*ONE_PLY
		 jl   .9skip
		mov   eax, dword[.beta]
		add   eax, VALUE_MATE_IN_MAX_PLY-1
		cmp   eax, 2*(VALUE_MATE_IN_MAX_PLY-1)
		 ja   .9skip
    if USE_MATEFINDER =	1
		mov   eax, dword[.evalu]
	       test   byte[rbx+State.ply], 1
		 jz   .9skip
		add   eax, 2*VALUE_KNOWN_WIN-1
		cmp   eax, 4*VALUE_KNOWN_WIN-1
		jae   .9skip
    end	if

	     Assert   ne, dword[rbx-1*sizeof.State+State.currentMove], 0	, 'assertion dword[rbx-1*sizeof.State+State.currentMove] != MOVE_NONE failed in	Search.Step9'
	     Assert   ne, dword[rbx-1*sizeof.State+State.currentMove], MOVE_NULL, 'assertion dword[rbx-1*sizeof.State+State.currentMove] != MOVE_NULL failed in	Search.Step9'

		movzx ecx, byte[.improving]
		imul  ecx, 48
		mov   edi, dword[.beta]
		add   edi, 216
		sub   edi, ecx
		mov   eax, VALUE_INFINITE
		cmp   edi, eax
	      cmovg   edi, eax
		mov   dword[.rbeta], edi
		sub   edi, dword[rbx+State.staticEval]

	; initialize movepick
	     Assert   e, qword[rbx+State.checkersBB], 0, 'assertion qword[rbx+State.checkersBB]	== 0 failed in Search.Step9'
		lea   r15, [MovePick_PROBCUT_GEN]
		mov   dword[rbx+State.threshold], edi
		mov   ecx, dword[.ttMove]
		mov   eax, ecx
		mov   edx, ecx
		and   edx, 63
		shr   eax, 12
		movzx   edx, byte[rbp+Pos.board+rdx]
		xor   edi, edi
		test   ecx, ecx
		 jz   .9NoTTMove
		cmp   eax, MOVE_TYPE_CASTLE
		 je   .9NoTTMove
		cmp   eax, MOVE_TYPE_EPCAP
		 je   @1f
		test   edx, edx
		 jz   .9NoTTMove
	@1:
		mov   ecx, dword[.ttMove]
		call   Move_IsPseudoLegal
		test   rax, rax
		 jz   .9NoTTMove
		mov   ecx, dword[.ttMove]
		mov   edx, dword[rbx+State.threshold]
		call   SeeTestGe
		test   eax, eax
		 jz   .9NoTTMove
		mov   edi, dword[.ttMove]
		lea   r15, [MovePick_PROBCUT]
.9NoTTMove:
		mov   qword[rbx+State.stage], r15
		mov   dword[rbx+State.ttMove], edi

		mov    dword[.probCutCount], 0
.9moveloop:
		xor   esi, esi
	GetNextMove
		mov   r12d, eax
		; r12d = move
		mov   ecx, eax
		mov   r13d, dword[.rbeta]
        ; r13d = rbeta
		test   eax, eax
		 jz   .9moveloop_done
		call   Move_IsLegal
		test   eax, eax
		 jz   .9moveloop
		mov  eax, r12d
		cmp  dword[.excludedMove], r12d
		je   .9moveloop
		cmp  byte[.cutNode], 0
		setne  sil
		lea  esi, dword[2*rsi+2]

		cmp    dword[.probCutCount], esi
		jge   .9moveloop_done
		add    dword[.probCutCount], 1
		mov   ecx, r12d
		mov   dword[rbx+State.currentMove], ecx
		mov   eax, ecx
		shr   eax, 6
		and   eax, 63
		and   ecx, 63
		movzx   eax, byte[rbp+Pos.board+rax]
		shl   eax, 6
		add   eax, ecx
		shl   eax, 2+4+6
		add   rax, qword[rbp+Pos.counterMoveHistory]
		mov   qword[rbx+State.counterMoves], rax

		mov   ecx, r12d
		call   Move_GivesCheck
		mov   ecx, r12d
		mov   byte[rbx+State.givesCheck], al
		call   Move_Do__ProbCut

		mov  edi, dword[.depth]
		mov  ecx, dword[.rbeta]
		neg  ecx
		lea  edx, [rcx+1]
		xor  r8, r8
		movzx  r9d, byte[.cutNode]
		not  r9d
		lea   r10, [QSearch_NonPv_InCheck]
		lea   r11, [QSearch_NonPv_NoCheck]
		cmp   byte[rbx-1*sizeof.State+State.givesCheck], 0
	    cmovne   r11, r10
		call  r11
		neg  eax
		mov  esi, eax
		cmp  eax, dword[.rbeta]
		jge  @f
		mov   ecx, r12d
		call   Move_Undo
		mov   eax, esi
		cmp   esi, r13d
		jl   .9moveloop
    @@:
		mov  ecx, r13d
		neg  ecx
		lea  edx, [rcx+1]
		lea  r8d, [rdi - 4*ONE_PLY]
		movzx  r9d, byte[.cutNode]
		not  r9d
		call  Search_NonPv
		neg  eax
		mov  esi, eax

		mov   ecx, r12d
		call   Move_Undo
		mov   eax, esi
		cmp   esi, r13d
		jl   .9moveloop
		jmp   .Return

.9moveloop_done:
.9skip:
  end if


    ; Step 11. Internal iterative deepening (skipped when in check)
		mov   r8d, dword[.depth]
		mov   ecx, dword[.ttMove]
		test   ecx, ecx
		jnz   .10skip
		cmp   r8d, 8*ONE_PLY
		 jl   .10skip
		sub   r8d, 7*ONE_PLY
  if PvNode = 1
		mov   ecx, dword[.alpha]
		mov   edx, dword[.beta]
		movzx   r9d, byte[.cutNode]
		call   Search_Pv
  else
		mov   ecx, dword[.alpha]
		mov   edx, dword[.beta]
		movzx   r9d, byte[.cutNode]
		call   Search_NonPv
  end if
		mov   rcx, qword[.posKey]
		call   MainHash_Probe
		mov   qword[.tte], rax
		mov   qword[.ltte], rcx
		mov   byte[.ttHit], dl
		mov   rdi, rcx
		sar   rdi, 48
		shr   ecx, 16
		mov   dword[.ttMove], ecx

		lea  r8d, [rdi+VALUE_MATE_IN_MAX_PLY]
		test  edx, edx
		 jz  @1f
		cmp  edi, VALUE_NONE
		 je  @1f
		cmp  r8d, 2*VALUE_MATE_IN_MAX_PLY
		 jb  @1f
		movzx  r8d, byte[rbx+State.ply]
		mov  r9d, edi
		sar  r9d, 31
		xor  r8d, r9d
		add  edi, r9d
		sub  edi, r8d
        @1:
		mov  dword[.ttValue], edi

.10skip:

.moves_loop:        ; this is actually not the head of the loop
    ; The data at tte could have been changed by
    ;   Step 6. Razoring
    ;   Step 9. ProbCut
    ; Note that after
    ;   Step 10. Internal iterative deepening
    ; the data is reloaded
    ; Also, in the case of a tt miss, tte points to junk but must be used anyways.
    ; We reload the data in .ltte for its use in .singularExtensionNode.

		mov   rax, qword[.tte]
		mov   rax, qword[rax]
		mov   qword[.ltte], rax
.CMH  equ (rbx-1*sizeof.State+State.counterMoves)
.FMH  equ (rbx-2*sizeof.State+State.counterMoves)
.FMH2 equ (rbx-4*sizeof.State+State.counterMoves)
    ; initialize move pick
		mov   ecx, dword[.ttMove]
		mov   edx, dword[.depth]
		mov   dword[rbx+State.depth], edx
		mov   rdi, qword[rbp+Pos.counterMoves]
		mov   eax, dword[rbx-1*sizeof.State+State.currentMove]
		and   eax, 63
	      movzx   edx, byte[rbp+Pos.board+rax]
		shl   edx, 6
		add   edx, eax
		mov   eax, dword[rdi+4*rdx]
		mov   dword[rbx+State.countermove], eax
		lea   r15, [MovePick_CAPTURES_GEN]
		lea   r14, [MovePick_ALL_EVASIONS]
		mov   edi, ecx
		test   ecx, ecx
		 jz   .NoTTMove
		call   Move_IsPseudoLegal
		test   rax, rax
		cmovz   edi, eax
		 jz   .NoTTMove
		lea   r15, [MovePick_MAIN_SEARCH]
		lea   r14, [MovePick_EVASIONS]
.NoTTMove:
		mov   r8, qword[rbx+State.checkersBB]
		mov   rax, qword[rbx+State.killers]
		test   r8, r8
		cmovnz  r15, r14
		mov   qword[rbx+State.mpKillers], rax
		mov   dword[rbx+State.ttMove], edi
		mov   qword[rbx+State.stage], r15
		mov   eax, dword[.bestValue]
		mov   dword[.value], eax
		mov    esi, 63
		movzx  eax, byte[.improving]
		mov    edx, dword[.depth]
		mov    ecx, edx
		cmp    edx, esi
		cmova   ecx, esi
		lea   eax, [8*rax]
		lea   eax, [8*rax+rcx]
		shl   eax, 6
		mov   dword[.reductionOffset], eax
		xor   eax, eax
		mov   byte[.skipQuiets], al


  if RootNode = 1
		mov   byte[.singularExtensionNode],	al
  else
		mov   ecx, dword[.depth]
		cmp   ecx, 8*ONE_PLY
		setge   al
		mov   edx, dword[.ttMove]
		test   edx, edx
		setne   cl
		and   al, cl
		mov   edx, dword[.ttValue]
		cmp   edx, VALUE_NONE
		setne   cl
		and   al, cl
		mov   edx, dword[.excludedMove]
		test   edx, edx
		setz   cl
		and   al, cl
		mov   dl, byte[.ltte+MainHashEntry.genBound]
		test   dl, BOUND_LOWER
		setnz   cl
		and   al, cl
		movsx   edx, byte[.ltte+MainHashEntry.depth]
		add   edx, 3*ONE_PLY
		cmp   edx, dword[.depth]
		setge   cl
		and   al, cl
		mov   byte[.singularExtensionNode],	al
  end if

  if PvNode = 1
		mov   al, byte[.ltte+MainHashEntry.genBound]
		and   al, BOUND_EXACT
		cmp   al, BOUND_EXACT
		sete   al
		and   al, byte[.ttHit]
		mov   dword[.pvExact], eax
  end if

	mov   eax, dword[.ttMove]
	test  eax, eax
	setnz cl
	; ecx = ttMove
	mov  edx, eax
	and  edx, 63
	shr  eax, 14
	movzx  edx, byte[rbp+Pos.board+rdx]
	or  dl, byte[_CaptureOrPromotion_or+rax]
	and  dl, byte[_CaptureOrPromotion_and+rax]
	; edx = pos.capture_or_promotion(ttMove)
	test  edx, edx
	setnz  al
	and  eax, ecx
	mov  dword[.ttCapture], eax

  ; Step 12. Loop through moves
	 calign	  8
.MovePickLoop:	     ; this is the head	of the loop
		movsx   esi, byte[.skipQuiets]
    GetNextMove
		mov   dword[.move],	eax
		test   eax, eax
		 jz   .MovePickDone
		cmp   eax, dword[.excludedMove]
		 je   .MovePickLoop
    ; at the root search only moves in the move	list
  if RootNode =	1
		imul   ecx, dword[rbp-Thread.rootPos+Thread.PVIdx], sizeof.RootMove
		add   rcx, qword[rbp+Pos.rootMovesVec+RootMovesVec.table]
		mov   rdx, qword[rbp+Pos.rootMovesVec+RootMovesVec.ender]
    @1:
		cmp   rcx, rdx
		jae   .MovePickLoop
		cmp   eax, dword[rcx+RootMove.pv+4*0]
		lea   rcx, [rcx+sizeof.RootMove]
		jne   @1b
  end if
		mov   eax, dword[.moveCount]
		add   eax, 1
		mov   dword[rbx+State.moveCount], eax
		mov   dword[.moveCount], eax
		xor   eax, eax
  if PvNode = 1
		mov   qword[rbx+1*sizeof.State+State.pv], rax
  end if
		mov   dword[.extension], eax
  if USE_CURRMOVE = 1 &	VERBOSE	< 2 & RootNode = 1
		mov   eax, dword[rbp-Thread.rootPos+Thread.idx]
		test   eax, eax
		jnz   .PrintCurrentMoveRet
		call   Os_GetTime		 ; we are only polling the timer
		sub   rax, qword[time.startTime] ;  in the main thread at the root
		cmp   eax, CURRMOVE_MIN_TIME
		jge   .PrintCurrentMove
.PrintCurrentMoveRet:
  end if
		mov   ecx, dword[.move]
		mov   edx, ecx
		shr   edx, 6
		and   edx, 63
		movzx   edx, byte[rbp+Pos.board+rdx]
		mov   eax, ecx
		and   eax, 63
		shl   edx, 6
		add   edx, eax
		mov   dword[.moved_piece_to_sq], edx
    ; moved_piece_to_sq	= index	of [moved_piece][to_sq(move)]
		shr   ecx, 14
		movzx   eax, byte[rbp+Pos.board+rax]
		 or   al, byte[_CaptureOrPromotion_or+rcx]
		and   al, byte[_CaptureOrPromotion_and+rcx]
		mov   byte[.captureOrPromotion], al
		mov   ecx, dword[.move]
		call   Move_GivesCheck
		mov   byte[rbx+State.givesCheck], al
		mov   edi, dword[.depth]
		movzx   ecx, byte[.improving]
		shl   ecx, 4+2
		mov   ecx, dword[FutilityMoveCounts+rcx+4*rdi]
		sub   ecx, dword[.moveCount]
		sub   ecx, 1
		sub   edi, 16*ONE_PLY
		and   edi, ecx
		sar   edi, 31
		mov   byte[.moveCountPruning], dil
		mov   edi, eax  ; edi = givesCheck
    ; Step 13. Extend checks
		mov   al, byte[.singularExtensionNode]
		mov   ecx, dword[.move]
		test   al, al
		 jz   .12else
		cmp   ecx, dword[.ttMove]
		jne   .12else
		call   Move_IsLegal
		mov   edx, dword[.ttValue]
		mov   r8d, dword[.depth]
		movzx   r9d, byte[.cutNode]
		test   eax, eax
		 jz   .12else
		mov   eax, -VALUE_MATE
		sub   edx, r8d
		sub   edx, r8d
		cmp   edx, eax
		cmovl   edx, eax
		lea   ecx, [rdx-1]
		mov   edi, edx
		sar   r8d, 1
		mov   eax, dword[.move]
		mov   dword[rbx+State.excludedMove], eax
    ; The call to search_NonPV with the same value of ss messed up our
    ; move picker data. So we fix it.
		mov   r12, qword[rbx+State.stage]
		mov   r13, qword[rbx+State.ttMove]	    ; ttMove and Depth
		mov   r14, qword[rbx+State.countermove]	; counter move and gives check
		mov   r15, qword[rbx+State.mpKillers]
		call   Search_NonPv
		xor   ecx, ecx
		mov   dword[rbx+State.excludedMove], ecx
		cmp   eax, edi
		setl   cl
		mov   dword[.extension], ecx
		test  ecx, ecx
		jnz  @f
		movzx   r9d, byte[.cutNode]
		mov  r8d, dword[.beta]
		cmp  edi, r8d
		setg  cl
		and  ecx, r9d
		jz  @f
		mov  eax, r8d
		jmp .Return
@@:
    ; The call to search_NonPV with the	same value of ss messed	up our
    ; move picker data.	So we fix it.
		mov   qword[rbx+State.stage], r12
		mov   qword[rbx+State.ttMove], r13
		mov   qword[rbx+State.countermove],	r14
		mov   qword[rbx+State.mpKillers], r15
		jmp   .12done
.12else:
		test   edi, edi
		 jz   .12dont_extend
    SeeSignTest	     .12extend_oneply
		test   eax, eax
		 jz   .12dont_extend
.12extend_oneply:
		mov   dword[.extension], 1
		jmp  .12done
.12dont_extend:
		mov   ecx, dword[.move]
		and  ecx, 0xC000
		cmp  ecx, 0xC000
		jne @f
		mov   dword[.extension], 1
.12done:
@@:

    ; Step 14. Pruning at shallow depth
		mov   r12d, dword[.move]
		shr   r12d, 6
		and   r12d, 63				; r12d = from
		mov   r13d, dword[.move]
		and   r13d, 63				; r13d = to
		movzx   r14d, byte[rbp	+ Pos.board + r12]	; r14d = from piece
		movzx   r15d, byte[rbp	+ Pos.board + r13]	; r15d = to piece

		mov   ecx, dword[.moveCount]
		mov   eax, dword[.extension]
		mov   edx, dword[.depth]
		mov   esi, 63
		cmp   ecx, esi
		cmova   ecx, esi
		sub   eax, 1
		add   ecx, dword[.reductionOffset]
		add   eax, edx
		mov   r9d, dword[Reductions + 4*(rcx	+ 2*64*64*PvNode)]
		mov   dword[.reduction], r9d
		mov   dword[.newDepth],	eax

    ; edx = depth
  if (RootNode = 0 & USE_MATEFINDER = 0) | (PvNode = 0 & USE_MATEFINDER	= 1)
		mov   r8d, dword[rbp+Pos.sideToMove]
		mov   ecx, dword[.bestValue]
	      movzx   esi, word[rbx+State.npMaterial+2*0]
		add   eax, ecx
		cmp   ecx, VALUE_MATED_IN_MAX_PLY
		jle   .13done
	      movzx   ecx, word[rbx+State.npMaterial+2*r8]
	       test   ecx, ecx
		 jz   .13done
		mov   al, byte[.captureOrPromotion]
		 or   al, byte[rbx+State.givesCheck]
		jnz   .13else
		lea   ecx, [8*r8+Pawn]
		cmp   r14d, ecx
		jne   @f
		imul   r8d, 56
		xor   r8d, r12d
		cmp   r8d, SQ_A5
		jae   .13else
@@:
    ; Move count based pruning
		mov   al, byte[.moveCountPruning]
		 or   byte[.skipQuiets], al
		mov   edi, dword[.newDepth]
	       test   al, al
		jnz   .MovePickLoop
		sub   edi, dword[.reduction]
    ; edi = lmrDepth
    ; Countermoves based pruning
		mov   r8, qword[.CMH]
		mov   r9, qword[.FMH]
		lea   r11, [8*r14]
		lea   r11, [8*r11+r13]
		mov   eax, dword[r8+4*r11]
		mov   ecx, dword[r9+4*r11]
		xor   edx, edx
		mov   r10d, 2
		mov   r9d, 3
		cmp   edx, dword[rbx-1*sizeof.State+State.statScore]
		cmovl  r10d, r9d
		cmp   dword[rbx-1*sizeof.State+State.moveCount], 1
		cmove r10d, r9d
		cmp   edi, r10d
		jg  @f
  if CounterMovePruneThreshold <> 0     ; code assumes
		err
  end if
		and   eax, ecx
		 js   .MovePickLoop
	@@:
    ; Futility pruning:	parent node
		xor   edx, edx
		cmp   edi, 7*ONE_PLY
		jge   @f
	    test  edi, edi
	    cmovs edi, edx
	    imul  eax, edi, 200
		add   eax, 256
		cmp   rdx, qword[rbx+State.checkersBB]
		jne   @f
		add   eax, dword[rbx+State.staticEval]
		cmp   eax, dword[.alpha]
		jle   .MovePickLoop
@@:
    ; Prune moves with negative	SEE at low depths
		mov   ecx, dword[.move]
	    imul   edx, edi, -29
	    imul   edx, edi
	    call   SeeTestGe
	    test   eax, eax
		jz   .MovePickLoop
		jmp   .13done
.13else:
		mov   ecx, dword[.move]
		cmp   byte[.extension],	0
		jne   .13done

		imul  edx, -PawnValueEg
	    call   SeeTestGe
	    test   eax, eax
		jz   .MovePickLoop
.13done:
  end if

    ; Speculative prefetch as early as possible
		shl   r14d, 6+3
		shl   r15d, 6+3
		mov   rax, qword[rbx+State.key]
		xor   rax, qword[Zobrist_side]
		xor   rax, qword[Zobrist_Pieces+r14+8*r12]
		xor   rax, qword[Zobrist_Pieces+r14+8*r13]
		xor   rax, qword[Zobrist_Pieces+r15+8*r13]
                mul   dword[mainHash.clusterCount]
		shl   rdx, 5
		add   rdx, qword[mainHash.table]
	prefetchnta   [rdx]
		shr   r14d, 6+3
		shr   r15d, 6+3

    ; Check for legality just before making the move
  if RootNode = 0
		mov   ecx, dword[.move]
	       call   Move_IsLegal
	       test   rax, rax
		 jz   .IllegalMove
  end if
		mov   ecx, dword[.move]
		mov   eax, dword[.moved_piece_to_sq]
		shl   eax, 2+4+6
		add   rax, qword[rbp+Pos.counterMoveHistory]
		mov   dword[rbx+State.currentMove],	ecx
		mov   qword[rbx+State.counterMoves], rax

    ; Step 15. Make the move
	       call   Move_Do__Search

    ; Step 16. Reduced depth search (LMR)
		mov   edx, dword[.depth]
		mov   ecx, dword[.moveCount]
		cmp   edx, 3*ONE_PLY
		jl   .StartStep17
		cmp   ecx, 1
		jbe   .StartStep17
  if USE_MATEFINDER = 1
		cmp   dl, byte[rbp-Thread.rootPos+Thread.selDepth]
		jae   .StartStep17
		cmp   byte[rbx-1*sizeof.State+State.ply], 3
		 ja   @1f
		cmp   edx, 16
		jae   .StartStep17
    @1:
  end if
		mov   r8l, byte[.captureOrPromotion]
		mov   edi, dword[.reduction]
		mov   ecx, 15
		test   r8l, r8l
		 jz   @f
		cmp   byte[.moveCountPruning], 0
		je   .StartStep17
    ; r12d = from
    ; r13d = to
    ; r14d = from piece
    ; r15d = to	piece
    ; ecx = 15

@@:
    ; Decrease reduction if opponent's move count is high
		cmp  ecx, dword[rbx - 2*sizeof.State + State.moveCount]
		sbb  edi, 0
		test   r8l, r8l
		jnz   .15ReadyToSearch
    ; Decrease reduction for exact PV nodes
  if PvNode = 1
		sub   edi, dword[.pvExact]
	end if
    ; Increase reduction if ttMove is a capture
		add   edi, dword[.ttCapture]
    ; Increase reduction for cut nodes
		cmp   byte[.cutNode], 0
		 jz   .15testA
		add   edi, 2*ONE_PLY
		jmp   .15skipA
.15testA:
		mov   ecx, dword[.move]
		cmp   ecx, MOVE_TYPE_PROM shl 12
		jae   .15skipA
		mov   r9d, r12d
		mov   r8d, r13d
		xor   edx, edx
	       call   SeeTestGe.HaveFromTo
	       test   eax, eax
		jnz   .15skipA
		sub   edi, 2*ONE_PLY
.15skipA:
		mov   ecx, dword[.move]
		and   ecx, 64*64-1
		mov   edx, dword[.moved_piece_to_sq]
		mov   r9, qword[.CMH-1*sizeof.State]
		mov   r10, qword[.FMH-1*sizeof.State]
		mov   r11, qword[.FMH2-1*sizeof.State]
		mov   eax, dword[rbp+Pos.sideToMove]
		xor   eax, 1
		shl   eax, 12+2
		add   rax, qword[rbp+Pos.history]
		mov   eax, dword[rax+4*rcx]
		sub   eax, 4000
		mov   ecx, dword[rbx-2*sizeof.State+State.statScore]
		add   eax, dword[r9+4*rdx]
		add   eax, dword[r10+4*rdx]
		add   eax, dword[r11+4*rdx]
		mov   dword[rbx - 1*sizeof.State + State.statScore], eax

   ; Decrease/increase reduction by comparing opponent's stat score
		mov   edx, ecx
		xor   edx, eax
		and   ecx, edx
		shr   ecx, 31
		sub   edi, ecx
		and   edx, eax
		shr   edx, 31
		add   edi, edx

; // Decrease/increase reduction for moves with a good/bad history.
		mov   ecx, eax
		mov   edx,  0x68DB8BAD
		imul  edx
		sar   edx, 13
		sar   ecx, 31
		sub   edx, ecx
		sub   edi, edx
.15ReadyToSearch:
		xor  eax, eax
		test  edi, edi
		cmovs  edi, eax
		mov   eax, 1
		mov   r8d, dword[.newDepth]
		sub   r8d, edi
		cmp   r8d, eax
	      cmovl   r8d, eax
		mov   edi, r8d
		mov   edx, dword[.alpha]
		neg   edx
		lea   ecx, [rdx-1]
		 or   r9d, -1
	       call   Search_NonPv
		neg   eax
		xor   r9, r9
		cmp   eax, dword[.alpha]
		jle   .CheckFullPvSearch
		cmp   edi, dword[.newDepth]
  if PvNode = 1
		je   .CheckFullPvSearch
  else
		je   .18entry
  end if

.StartStep17:
; CheckFullDepthSearch
    ; Step 17. full depth search   this is for when step 15 is skipped
		xor   r9, r9
		mov   r8d, dword[.newDepth]
  if PvNode = 1
		cmp   dword[.moveCount], 1
		jbe   .DoFullPvSearch
  end if
    ; do full depth search
		lea   rax, [Search_NonPv]
		cmp   r8d, 1
	      cmovl   r8d, r9d
		mov   edx, dword[.alpha]
		neg   edx
		lea   ecx, [rdx-1]
	      movzx   r9d, byte[.cutNode]
		not   r9d
	       call   rax
		neg   eax
.CheckFullPvSearch:
  if PvNode = 1
		cmp   dword[.moveCount], 1
		je   .DoFullPvSearch
		cmp   eax, dword[.alpha]
		jle   .SkipFullPvSearch
    if RootNode	= 0
		cmp   eax, dword[.beta]
		jge   .SkipFullPvSearch
	end if
.DoFullPvSearch:
		lea   rax, [.pv]
		xor   r9, r9
		mov   qword[rbx+State.pv], rax
		mov   dword[rax], r9d
		mov   r8d, dword[.newDepth]
		lea   rax, [Search_Pv]
		cmp   r8d, 1
	      cmovl   r8d, r9d
		mov   ecx, dword[.beta]
		neg   ecx
		mov   edx, dword[.alpha]
		neg   edx
		xor   r9d, r9d
	       call   rax
		neg   eax
.SkipFullPvSearch:
  end if
    ; Step 18. Undo move
.18entry:
		mov   ecx, dword[.move]
		mov   edi, eax
		mov   dword[.value], eax
	       call   Move_Undo

   ; Step 19. Check for new best move
		xor   eax, eax
		cmp   al, byte[signals.stop]
		jne   .Return
  if RootNode =	1
		mov   ecx, dword[.move]
		mov   rdx, qword[rbp+Pos.rootMovesVec+RootMovesVec.table]
		lea   rdx, [rdx-sizeof.RootMove]
	@@:
		lea   rdx, [rdx+sizeof.RootMove]
	     Assert   b, rdx, qword[rbp+Pos.rootMovesVec+RootMovesVec.ender], 'cant	find root move'
		cmp   ecx, dword[rdx+RootMove.pv+4*0]
		jne   @b
		mov   esi, 1
		mov   r10d,	-VALUE_INFINITE
		cmp   esi, dword[.moveCount]
		 je   @f
		cmp   edi, dword[.alpha]
		jle   .FoundRootMoveDone
	    _vmovsd   xmm0,	qword[rbp-Thread.rootPos+Thread.bestMoveChanges]
	    _vaddsd   xmm0,	xmm0, qword[constd._1p0]
	    _vmovsd   qword[rbp-Thread.rootPos+Thread.bestMoveChanges],	xmm0
	@@:
		mov   r10d,	edi
	      movzx   eax, byte[rbp-Thread.rootPos+Thread.selDepth]
		mov   rcx, qword[rbx+1*sizeof.State+State.pv]
		mov   dword[rdx+RootMove.selDepth],	eax
		jmp   @2f
    @1:
		add   rcx, 4
		mov   dword[rdx+RootMove.pv+4*rsi],	eax
		add   esi, 1
    @2:
		mov   eax, dword[rcx]
	       test   eax, eax
		jnz   @1b
		mov   dword[rdx+RootMove.pvSize], esi
.FoundRootMoveDone:
		mov   dword[rdx+RootMove.score], r10d
  end if
    ; check for new best move
		mov   ecx, dword[.move]
		cmp   edi, dword[.bestValue]
		jle   .18NoNewValue
		mov   dword[.bestValue], edi
		cmp   edi, dword[.alpha]
		jle   .18NoNewValue
		mov   dword[.bestMove],	ecx
  if PvNode = 1	& RootNode = 0
		mov   r8, qword[rbx+0*sizeof.State+State.pv]
		mov   r9, qword[rbx+1*sizeof.State+State.pv]
		xor   eax, eax
		mov   dword[r8], ecx
		add   r8, 4
	       test   r9, r9
		 jz   @2f
    @1:
		mov   eax, dword[r9]
		add   r9, 4
    @2:
		mov   dword[r8], eax
		add   r8, 4
	       test   eax, eax
		jnz   @1b
  end if
  if PvNode = 1
		cmp   edi, dword[.beta]
		jge   .18fail_high
		mov   dword[.alpha], edi
		jmp   .18NoNewValue
  end if
.18fail_high:
	     Assert   ge, edi, dword[.beta], 'did not fail high in Search'
		xor  eax, eax
		mov  dword[rbx + State.statScore], eax
		jmp  .MovePickDone
.18NoNewValue:
		mov   ecx, dword[.move]
		mov   eax, dword[.quietCount]
		mov   edx, dword[.captureCount]
		cmp   ecx, dword[.bestMove]
		je   .MovePickLoop
		cmp   byte[.captureOrPromotion], 0
		jnz   @1f
		cmp   eax, 64
		jae   .MovePickLoop
		mov   dword[.quietsSearched+4*rax],	ecx
		add   eax, 1
		mov   dword[.quietCount], eax
		jmp   .MovePickLoop
  @1:
		cmp   edx, 32
		jae   .MovePickLoop
		mov   dword[.capturesSearched+4*rdx], ecx
		add   edx, 1
		mov   dword[.captureCount],	edx
		jmp   .MovePickLoop

.MovePickDone:
    ; Step 20. Check for mate and stalemate
		mov   eax, dword[rbx-1*sizeof.State+State.currentMove]
		and   eax, 63
	      movzx   ecx, byte[rbp+Pos.board+rax]
		shl   ecx, 6
		lea   r15d,	[rax+rcx]
		mov   r12d,	dword[.bestMove]
		mov   r13d, dword[.depth]
		mov   edi, dword[.bestValue]
		stat_bonus  r10d, rax, r13
		add   r13d, 1
		stat_bonus  r14d, rax, r13
		sub   r13d, 1
    ; r15d = offset of [piece_on(prevSq),prevSq]
    ; r12d = move
    ; r13d = depth
    ; r10d = bonus
    ; r14d = statbonus (depth + 1)
		mov   edi, dword[.bestValue]
		cmp   dword[.moveCount], 0
		 je   .20Mate
	       test   r12d,	r12d
		 jz   .20CheckBonus
.20Quiet:
		mov   edx, r12d
		mov   r8d, r12d
		and   r8d, 63
		shr   edx, 14
		movzx   r8d, byte[rbp+Pos.board+r8]
		or   r8b, byte[_CaptureOrPromotion_or+rdx]
		mov  dl, byte[_CaptureOrPromotion_and+rdx]
		test   r8b, dl
		jnz   @1f

		mov  eax, dword[.beta]
		add  eax, PawnValueMg
		cmp  edi, eax
		cmovg  r10d, r14d

		UpdateStats   r12d, .quietsSearched, dword[.quietCount], r11d, r10d, r15
 @1:
		UpdateCaptureStats  r12d, .capturesSearched, dword[.captureCount], r11d, r14d

		cmp   dword[rbx-1*sizeof.State+State.moveCount], 1
		je  @2f

		mov  eax, dword[rbx-1*sizeof.State+State.killers]
		cmp  eax, dword[rbx-1*sizeof.State+State.currentMove]
		jne  .20TTStore

@2:
		cmp   byte[rbx+State.capturedPiece], 0
		jne   .20TTStore
		mov  r11d, r14d
		neg  r11d ; negative bonus
		cmp   r14d, BONUS_MAX
		jae   .20TTStore
		abs_bonus r11d, r14d
		UpdateCmStats   (rbx-1*sizeof.State), r15, r11d, r14d, r8
		jmp   .20TTStore

.20Mate:
		mov   r14d, dword[.excludedMove]
		mov   rax, qword[rbx+State.checkersBB]
		movzx edi, byte[rbx+State.ply]
		sub   edi, VALUE_MATE
		test  rax, rax
		cmovz edi, eax          ; cmovz edi, VALUE_DRAW
		test   r14d, r14d
		cmovnz edi, dword[.alpha]
		jmp .20TTStore
.20CheckBonus:
    ; we already checked that bestMove = 0
	if PvNode = 1
		jmp @f
	else
		cmp  r13d, 3*ONE_PLY
		jb  .20TTStore
	end if

	@@:
		cmp   byte[rbx+State.capturedPiece], 0
		jne   .20TTStore
		mov   r11d, r10d
		cmp   r10d, BONUS_MAX
		jae   .20TTStore
		abs_bonus r11d, r10d
		UpdateCmStats   (rbx-1*sizeof.State), r15, r11d, r10d, r8
.20TTStore:
    ; edi = bestValue
		mov   r14d, dword[.excludedMove]
		mov   r9, qword[.posKey]
		lea   ecx, [rdi+VALUE_MATE_IN_MAX_PLY]
		mov   r8, qword[.tte]
		shr   r9, 48
		mov   edx, edi
		test   r14d, r14d
		jnz   .ReturnBestValue
		cmp   ecx, 2*VALUE_MATE_IN_MAX_PLY
		jae   .20ValueToTT
.20ValueToTTRet:
  if PvNode = 0
		mov   eax, dword[.bestMove]
		xor   esi, esi
		cmp   edi, dword[.beta]
	      setge   sil
		add   esi, BOUND_UPPER
  else
		mov   eax, dword[.bestMove]
		mov   ecx, BOUND_LOWER
		cmp   eax, 1
		sbb   esi, esi
		lea   esi, [(BOUND_EXACT-BOUND_UPPER)*rsi+BOUND_EXACT]
		cmp   edi, dword[.beta]
	     cmovge   esi, ecx
  end if
      MainHash_Save   .ltte, r8, r9w, edx, sil,	byte[.depth], eax, word[.pureStaticEval]
.ReturnBestValue:
		mov   eax, edi
.Return:
Display	2, "Search returning %i0%n"
		add   rsp, .localsize
		pop   r15 r14 r13 r12 rdi rsi rbx
		ret
.ValueFromTT:
		movzx   r8d, byte[rbx+State.ply]
		mov   r9d, edi
		sar   r9d, 31
		xor   r8d, r9d
		add   edi, r9d
		sub   edi, r8d
		jmp   .ValueFromTTRet
.IllegalMove:
		mov   eax, dword[.moveCount]
		sub   eax, 1
		mov   dword[rbx+State.moveCount], eax
		mov   dword[.moveCount], eax
		jmp   .MovePickLoop

	if RootNode = 0

		calign  8
		.AbortSearch_PlyBigger:
		value_draw  rax, dword[.depth], qword[rbp-Thread.rootPos+Thread.nodes]
		mov  rcx, qword[rbx + State.checkersBB]
		test  rcx, rcx
		jz  .Return
		call  Evaluate

		calign   8
		.AbortSearch_PlySmaller:
		value_draw  rax, dword[.depth], qword[rbp-Thread.rootPos+Thread.nodes]
		jmp  .Return
	end if

	if PvNode = 0
		calign   8
		.ReturnTTValue:
		; edi = ttValue
		mov   r12d,	ecx
		mov   r13d, dword[.depth]
		stat_bonus  r10d, rax, r13
		; r12d = move
		; r13d = depth
		; r10d = bonus
		mov   eax, r12d
		mov   edx, r12d
		and   edx, 63
		shr   eax, 14
		movzx   edx, byte[rbp+Pos.board+rdx]
		or   dl, byte[_CaptureOrPromotion_or+rax]
		and   dl, byte[_CaptureOrPromotion_and+rax]
		; dl = capture or promotion
		mov   eax, edi
		test   ecx, ecx
		jz   .Return

		; ttMove is quiet; update move sorting heuristics on TT hit
		cmp   edi, dword[.beta]
		jl   .ReturnTTValue_Penalty

		mov   eax, dword[rbx-1*sizeof.State+State.currentMove]
		and   eax, 63
		movzx   ecx, byte[rbp+Pos.board+rax]
		shl   ecx, 6
		lea   r15d, [rax+rcx]
		; r15d = offset of [piece_on(prevSq),prevSq]
		test   dl, dl
		jnz   .ReturnTTValue_UpdateCaptureStats

		UpdateStats   r12d, 0, 0, r11d, r10d, r15

.ReturnTTValue_UpdateCaptureStats:
.ReturnTTValue_UpdateStatsDone:
		add   r13, 1
		stat_bonus  r10d, rax, r13
		sub   r13, 1
    ; r10d = penalty

		cmp   dword[rbx-1*sizeof.State+State.moveCount], 1
		mov   eax, edi
		je  @1f

		mov  ecx, dword[rbx-1*sizeof.State+State.killers]
		cmp  ecx, dword[rbx-1*sizeof.State+State.currentMove]
		jne  .Return

	@1:
		cmp   byte[rbx+State.capturedPiece], 0
		mov   eax, edi
		jne   .Return

		mov   r11d, r10d
		neg   r11d ; negative bonus
		cmp   r10d, BONUS_MAX
		mov   eax, edi
		jae   .Return

		abs_bonus r11d, r10d
		UpdateCmStats (rbx-1*sizeof.State), r15, r11d, r10d, r8
		mov   eax, edi
		jmp   .Return

.ReturnTTValue_Penalty:
		and   ecx, 64*64-1
		mov   r8d, dword[rbp+Pos.sideToMove]
		shl   r8d, 12+2
		add   r8, qword[rbp+Pos.history]
		lea   r8, [r8+4*rcx]
		; r8 = offset in history table
		test   dl, dl
		jnz   .Return

		mov   r11d, r10d
		neg   r11d
		cmp   r10d, BONUS_MAX
		jae   .Return

		abs_bonus r11d, r10d
		history_update r8, r11d, r10d
		mov   r9d, r12d
		and   r9d, 63
		mov   eax, r12d
		shr   eax, 6
		and   eax, 63
		movzx   eax, byte[rbp+Pos.board+rax]
		shl   eax, 6
		add   r9d, eax
    ; r9 = offset in cm table
		abs_bonus r11d, r10d
		UpdateCmStats   (rbx-0*sizeof.State), r9, r11d, r10d, r8
		mov  eax, edi
		jmp  .Return
  end if

	 calign   8
.20ValueToTT:
	      movzx   edx, byte[rbx+State.ply]
		mov   eax, edi
		sar   eax, 31
		xor   edx, eax
		sub   edx, eax
		add   edx, edi
		jmp   .20ValueToTTRet

  if RootNode = 0
	 calign   8
.CheckDraw_Cold:
     PosIsDraw_Cold   .AbortSearch_PlySmaller, .CheckDraw_ColdRet
    if USE_SYZYGY
	     calign   8
.CheckTablebase:
		mov   ecx, dword[.depth]
		mov   rax, qword[rbp+Pos.typeBB+8*White]
		 or   rax, qword[rbp+Pos.typeBB+8*Black]
	    _popcnt   rax, rax,	rdx
		cmp   ecx, dword[Tablebase_ProbeDepth]
		jge   .DoTbProbe
		cmp   eax, dword[Tablebase_Cardinality]
		jge   .CheckTablebaseReturn
.DoTbProbe:
Display	2,"DoTbProbe %p%n"
		lea   r15, [.success]
	       call   Tablebase_Probe_WDL
		mov   edx, dword[.success]
	       test   edx, edx
		 jz   .CheckTablebaseReturn
Display	2,"Tablebase_Probe_WDL returned	%i0%n"
	      movsx   ecx, byte[Tablebase_UseRule50]
		lea   edx, [2*rax]
		and   edx, ecx
		mov   edi, edx
		mov   r8d, -VALUE_MATE + MAX_PLY + 1
	      movzx   r9d, byte[rbx+State.ply]
		add   r9d, r8d
		cmp   eax, ecx
	      cmovl   edx, r8d
	      cmovl   edi, r9d
		neg   ecx
		mov   r8d, VALUE_MATE -	MAX_PLY - 1
		neg   r9d
		cmp   eax, ecx
	      cmovg   edx, r8d
	      cmovg   edi, r9d
    ; edi = value
    ; edx = value_to_tt(value, ss->ply)
		inc   qword[rbp-Thread.rootPos+Thread.tbHits]
		mov   r9, qword[.posKey]
		lea   ecx, [rdi+VALUE_MATE_IN_MAX_PLY]
		mov   r8, qword[.tte]
		shr   r9, 48
		mov   eax, MAX_PLY - 1
		mov   esi, dword[.depth]
		add   esi, 6
		cmp   esi, eax
	      cmovg   esi, eax
		xor   eax, eax
      MainHash_Save   .ltte, r8, r9w, edx, BOUND_EXACT,	sil, eax, VALUE_NONE
		mov   eax, edi
		jmp   .Return
    end if
  end if
  if USE_CURRMOVE = 1 &	VERBOSE	< 2 & RootNode = 1
	 calign   8
.PrintCurrentMove:
		cmp   byte[options.displayInfoMove],	0
		 je   .PrintCurrentMoveRet
		lea   rdi, [Output]
		mov   eax, dword[.depth]
		mov   ecx, dword[.move]
		mov   edx, dword[.moveCount]
		add   edx, dword[rbp-Thread.rootPos+Thread.PVIdx]
	       push   rdx rdx rcx rax
		lea   rcx, [sz_format_currmove]
		mov   rdx, rsp
		xor   r8, r8
	       call   PrintFancy
		pop   rax rax rax rax
	       call   WriteLine_Output
		jmp   .PrintCurrentMoveRet
  end if
end macro
