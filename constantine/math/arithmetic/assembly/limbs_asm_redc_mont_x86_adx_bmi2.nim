# Constantine
# Copyright (c) 2018-2019    Status Research & Development GmbH
# Copyright (c) 2020-Present Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  std/macros,
  # Internal
  ../../../platforms/abstractions,
  ./limbs_asm_modular_x86

# ############################################################
#
#        Assembly implementation of finite fields
#
# ############################################################

static: doAssert UseASM_X86_64

# MULX/ADCX/ADOX
{.localPassC:"-madx -mbmi2".}
# Necessary for the compiler to find enough registers (enabled at -O1)
{.localPassC:"-fomit-frame-pointer".}

# No exceptions allowed
{.push raises: [].}

# Montgomery reduction
# ------------------------------------------------------------

macro redc2xMont_adx_gen[N: static int](
       r_PIR: var array[N, SecretWord],
       a_PIR: array[N*2, SecretWord],
       M_PIR: array[N, SecretWord],
       m0ninv_REG: BaseType,
       spareBits: static int, skipFinalSub: static bool
      ) =

  # No register spilling handling
  doAssert N <= 6, "The Assembly-optimized montgomery multiplication requires at most 6 limbs."

  result = newStmtList()

  var ctx = init(Assembler_x86, BaseType)
  let
    # We could force M as immediate by specializing per moduli
    M = init(OperandArray, nimSymbol = M_PIR, N, PointerInReg, Input)

  let uSlots = N+1
  let vSlots = max(N-1, 5)

  var # Scratchspaces
    u = init(OperandArray, nimSymbol = ident"U", uSlots, ElemsInReg, InputOutput_EnsureClobber)
    v = init(OperandArray, nimSymbol = ident"V", vSlots, ElemsInReg, InputOutput_EnsureClobber)

  # Prologue
  let usym = u.nimSymbol
  let vsym = v.nimSymbol
  result.add quote do:
    static: doAssert: sizeof(SecretWord) == sizeof(ByteAddress)
    var `usym`{.noinit.}: Limbs[`uSlots`]
    var `vsym` {.noInit.}: Limbs[`vSlots`]
    `vsym`[0] = cast[SecretWord](`r_PIR`[0].unsafeAddr)
    `vsym`[1] = cast[SecretWord](`a_PIR`[0].unsafeAddr)
    `vsym`[2] = SecretWord(`m0ninv_REG`)

  let r_temp = v[0].asArrayAddr(len = N)
  let a = v[1].asArrayAddr(len = 2*N)
  let m0ninv = v[2]
  let lo = v[3]
  let hi = v[4]

  # Algorithm
  # ---------------------------------------------------------
  # for i in 0 .. n-1:
  #   hi <- 0
  #   m <- a[i] * m0ninv mod 2ʷ (i.e. simple multiplication)
  #   for j in 0 .. n-1:
  #     (hi, lo) <- a[i+j] + m * M[j] + hi
  #     a[i+j] <- lo
  #   a[i+n] += hi
  # for i in 0 .. n-1:
  #   r[i] = a[i+n]
  # if r >= M:
  #   r -= M

  ctx.mov rdx, m0ninv

  for i in 0 ..< N:
    ctx.mov u[i], a[i]

  for i in 0 ..< N:
    # RDX contains m0ninv at the start of each loop
    ctx.comment ""
    ctx.imul rdx, u[0] # m <- a[i] * m0ninv mod 2ʷ
    ctx.comment "---- Reduction " & $i
    ctx.`xor` u[N], u[N]

    for j in 0 ..< N-1:
      ctx.comment ""
      ctx.mulx hi, lo, M[j], rdx
      ctx.adcx u[j], lo
      ctx.adox u[j+1], hi

    # Last limb
    ctx.comment ""
    ctx.mulx hi, lo, M[N-1], rdx
    ctx.mov rdx, m0ninv # Reload m0ninv for next iter
    ctx.adcx u[N-1], lo
    ctx.adox hi, u[N]
    ctx.adcx u[N], hi

    u.rotateLeft()

  ctx.mov rdx, r_temp
  let r = rdx.asArrayAddr(len = N)

  # This does a[i+n] += hi
  # but in a separate carry chain, fused with the
  # copy "r[i] = a[i+n]"
  for i in 0 ..< N:
    if i == 0:
      ctx.add u[i], a[i+N]
    else:
      ctx.adc u[i], a[i+N]

  let t = repackRegisters(v, u[N])

  if spareBits >= 2 and skipFinalSub:
    for i in 0 ..< N:
      ctx.mov r[i], t[i]
  elif spareBits >= 1:
    ctx.finalSubNoCarryImpl(r, u, M, t)
  else:
    ctx.finalSubMayCarryImpl(r, u, M, t, hi)

  # Code generation
  result.add ctx.generate()

func redcMont_asm_adx_inline*[N: static int](
       r: var array[N, SecretWord],
       a: array[N*2, SecretWord],
       M: array[N, SecretWord],
       m0ninv: BaseType,
       spareBits: static int,
       skipFinalSub: static bool = false
      ) {.inline.} =
  ## Constant-time Montgomery reduction
  ## Inline-version
  redc2xMont_adx_gen(r, a, M, m0ninv, spareBits, skipFinalSub)

func redcMont_asm_adx*[N: static int](
       r: var array[N, SecretWord],
       a: array[N*2, SecretWord],
       M: array[N, SecretWord],
       m0ninv: BaseType,
       spareBits: static int,
       skipFinalSub: static bool = false
      ) =
  ## Constant-time Montgomery reduction
  redcMont_asm_adx_inline(r, a, M, m0ninv, spareBits, skipFinalSub)

# Montgomery conversion
# ----------------------------------------------------------

macro mulMont_by_1_adx_gen[N: static int](
       t_EIR: var array[N, SecretWord],
       M_PIR: array[N, SecretWord],
       m0ninv_REG: BaseType) =

  # No register spilling handling
  doAssert N <= 6, "The Assembly-optimized montgomery reduction requires at most 6 limbs."

  result = newStmtList()

  var ctx = init(Assembler_x86, BaseType)
  # On x86, compilers only let us use 15 out of 16 registers
  # RAX and RDX are defacto used due to the MUL instructions
  # so we store everything in scratchspaces restoring as needed
  let
    scratchSlots = 1

    t = init(OperandArray, nimSymbol = t_EIR, N, ElemsInReg, InputOutput_EnsureClobber)
    # We could force M as immediate by specializing per moduli
    M = init(OperandArray, nimSymbol = M_PIR, N, PointerInReg, Input)
    # MultiPurpose Register slots
    scratch = init(OperandArray, nimSymbol = ident"scratch", scratchSlots, ElemsInReg, InputOutput_EnsureClobber)

    # MUL requires RAX and RDX

    m0ninv = Operand(
               desc: OperandDesc(
                 asmId: "[m0ninv]",
                 nimSymbol: m0ninv_REG,
                 rm: MemOffsettable,
                 constraint: Input,
                 cEmit: "&" & $m0ninv_REG
               )
             )

    C = scratch[0] # Stores the high-part of muliplication

  let scratchSym = scratch.nimSymbol
  
  # Copy a in t
  result.add quote do:
    var `scratchSym` {.noInit.}: Limbs[`scratchSlots`]

  # Algorithm
  # ---------------------------------------------------------
  # for i in 0 .. n-1:
  #   m <- t[0] * m0ninv mod 2ʷ (i.e. simple multiplication)
  #   C, _ = t[0] + m * M[0]
  #   for j in 1 .. n-1:
  #     (C, t[j-1]) <- r[j] + m*M[j] + C
  #   t[n-1] = C

  # Low-level optimizations
  # https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-optimization-manual.pdf
  # Section 3.5.1.8 xor'ing a reg with itself is free (except for instruction code size)

  ctx.comment "for i in 0 ..< N:"
  for i in 0 ..< N:
    ctx.comment "  m <- t[0] * m0ninv mod 2ʷ"
    ctx.mov rdx, m0ninv
    ctx.imul rdx, t[0]

    # Create 2 parallel carry-chains for adcx and adox
    # We need to clear the carry/overflow flags first for ADCX/ADOX
    # with the smallest instruction if possible (xor rax, rax)
    # to reduce instruction-cache miss
    ctx.comment "  C, _ = t[0] + m * M[0]"
    ctx.`xor` rax, rax
    ctx.mulx C, rax, M[0], rdx
    ctx.adcx rax, t[0] # Set C', the carry flag for future adcx, but don't accumulate in C yet
    ctx.mov t[0], C

    # for j=1 to N-1
    #   (S,t[j-1]) := t[j] + m*M[j] + S
    ctx.comment "  for j=1 to N-1"
    ctx.comment "    (C,t[j-1]) := t[j] + m*M[j] + C"
    for j in 1 ..< N:
      ctx.adcx t[j-1], t[j]
      ctx.mulx t[j], C, M[j], rdx
      ctx.adox t[j-1], C

    ctx.comment "  final carries"
    ctx.mov rax, 0
    ctx.adcx t[N-1], rax
    ctx.adox t[N-1], rax

  result.add ctx.generate()

func fromMont_asm_adx*(r: var Limbs, a, M: Limbs, m0ninv: BaseType) =
  ## Constant-time Montgomery residue form to BigInt conversion
  ## Requires ADX and BMI2 instruction set
  var t{.noInit.} = a
  block:
    t.mulMont_by_1_adx_gen(M, m0ninv)

  block: # Map from [0, 2p) to [0, p)
    var workspace{.noInit.}: typeof(r)
    r.finalSub_gen(t, M, workspace, mayCarry = false)
