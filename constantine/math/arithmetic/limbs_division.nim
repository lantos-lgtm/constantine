# Constantine
# Copyright (c) 2018-2019    Status Research & Development GmbH
# Copyright (c) 2020-Present Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ../../platforms/abstractions

# No exceptions allowed
{.push raises: [].}

# ############################################################
#
#              Division and Modular Reduction
#
# ############################################################
#
# To avoid code-size explosion due to monomorphization
# and given that reductions are not in hot path in Constantine
# we use type-erased procedures, instead of instantiating
# one per number of limbs combination

# Type-erasure
# ------------------------------------------------------------

type
  LimbsView = ptr UncheckedArray[SecretWord]
    ## Type-erased fixed-precision limbs
    ##
    ## This type mirrors the Limb type and is used
    ## for some low-level computation API
    ## This design
    ## - avoids code bloat due to generic monomorphization
    ##   otherwise limbs routines would have an instantiation for
    ##   each number of words.
    ##
    ## Accesses should be done via BigIntViewConst / BigIntViewConst
    ## to have the compiler check for mutability

  # "Indirection" to enforce pointer types deep immutability
  LimbsViewConst = distinct LimbsView
    ## Immutable view into the limbs of a BigInt
  LimbsViewMut = distinct LimbsView
    ## Mutable view into a BigInt
  LimbsViewAny = LimbsViewConst or LimbsViewMut

# Deep Mutability safety
# ------------------------------------------------------------

template view(a: Limbs): LimbsViewConst =
  ## Returns a borrowed type-erased immutable view to a bigint
  LimbsViewConst(cast[LimbsView](a.unsafeAddr))

template view(a: var Limbs): LimbsViewMut =
  ## Returns a borrowed type-erased mutable view to a mutable bigint
  LimbsViewMut(cast[LimbsView](a.addr))

template `[]`*(v: LimbsViewConst, limbIdx: int): SecretWord =
  LimbsView(v)[limbIdx]

template `[]`*(v: LimbsViewMut, limbIdx: int): var SecretWord =
  LimbsView(v)[limbIdx]

template `[]=`*(v: LimbsViewMut, limbIdx: int, val: SecretWord) =
  LimbsView(v)[limbIdx] = val

# Copy
# ------------------------------------------------------------

func copyWords(
       a: LimbsViewMut, startA: int,
       b: LimbsViewAny, startB: int,
       numWords: int
     ) =
  ## Copy a slice of B into A. This properly deals
  ## with overlaps when A and B are slices of the same buffer
  if startA > startB:
    for i in countdown(numWords-1, 0):
      a[startA+i] = b[startB+i]
  else:
    for i in 0 ..< numWords:
      a[startA+i] = b[startB+i]

# Type-erased add-sub
# ------------------------------------------------------------

func cadd(a: LimbsViewMut, b: LimbsViewAny, ctl: SecretBool, len: int): Carry =
  ## Type-erased conditional addition
  ## Returns the carry
  ##
  ## if ctl is true: a <- a + b
  ## if ctl is false: a <- a
  ## The carry is always computed whether ctl is true or false
  ##
  ## Time and memory accesses are the same whether a copy occurs or not
  result = Carry(0)
  var sum: SecretWord
  for i in 0 ..< len:
    addC(result, sum, a[i], b[i], result)
    ctl.ccopy(a[i], sum)

func csub(a: LimbsViewMut, b: LimbsViewAny, ctl: SecretBool, len: int): Borrow =
  ## Type-erased conditional addition
  ## Returns the borrow
  ##
  ## if ctl is true: a <- a - b
  ## if ctl is false: a <- a
  ## The borrow is always computed whether ctl is true or false
  ##
  ## Time and memory accesses are the same whether a copy occurs or not
  result = Borrow(0)
  var diff: SecretWord
  for i in 0 ..< len:
    subB(result, diff, a[i], b[i], result)
    ctl.ccopy(a[i], diff)

# Modular reduction
# ------------------------------------------------------------

func numWordsFromBits(bits: int): int {.inline.} =
  const divShiftor = log2_vartime(uint32(WordBitWidth))
  result = (bits + WordBitWidth - 1) shr divShiftor

func shlAddMod_estimate(a: LimbsViewMut, aLen: int,
                        c: SecretWord, M: LimbsViewConst, mBits: int
                      ): tuple[neg, tooBig: SecretBool] =
  ## Estimate a <- a shl 2ʷ + c (mod M)
  ##
  ## with w the base word width, usually 32 on 32-bit platforms and 64 on 64-bit platforms
  ##
  ## Updates ``a`` and returns ``neg`` and ``tooBig``
  ## If ``neg``, the estimate in ``a`` is negative and ``M`` must be added to it.
  ## If ``tooBig``, the estimate in ``a`` overflowed and ``M`` must be substracted from it.

  # Aliases
  # ----------------------------------------------------------------------
  let MLen = numWordsFromBits(mBits)

  # Captures aLen and MLen
  template `[]`(v: untyped, limbIdxFromEnd: BackwardsIndex): SecretWord {.dirty.}=
    v[`v Len` - limbIdxFromEnd.int]

  # ----------------------------------------------------------------------
                                                 # Assuming 64-bit words
  let hi = a[^1]                                 # Save the high word to detect carries
  let R = mBits and (WordBitWidth - 1)           # R = mBits mod 64

  var a0, a1, m0: SecretWord
  if R == 0:                                     # If the number of mBits is a multiple of 64
    a0 = a[^1]                                   #
    copyWords(a, 1, a, 0, aLen-1)                # we can just shift words
    a[0] = c                                     # and replace the first one by c
    a1 = a[^1]
    m0 = M[^1]
  else:                                          # Else: need to deal with partial word shifts at the edge.
    a0 = (a[^1] shl (WordBitWidth-R)) or (a[^2] shr R)
    copyWords(a, 1, a, 0, aLen-1)
    a[0] = c
    a1 = (a[^1] shl (WordBitWidth-R)) or (a[^2] shr R)
    m0 = (M[^1] shl (WordBitWidth-R)) or (M[^2] shr R)

  # m0 has its high bit set. (a0, a1)/p0 fits in a limb.
  # Get a quotient q, at most we will be 2 iterations off
  # from the true quotient
  var q, r: SecretWord
  div2n1n(q, r, a0, a1, m0)                      # Estimate quotient
  q = mux(                                       # If n_hi == divisor
        a0 == m0, MaxWord,                       # Quotient == MaxWord (0b1111...1111)
        mux(
          q.isZero, Zero,                        # elif q == 0, true quotient = 0
          q - One                                # else instead of being of by 0, 1 or 2
        )                                        # we returning q-1 to be off by -1, 0 or 1
      )

  # Now substract a*2^64 - q*p
  var carry = Zero
  var over_p = CtTrue                            # Track if quotient greater than the modulus

  for i in 0 ..< MLen:
    var qp_lo: SecretWord

    block: # q*p
      # q * p + carry (doubleword) carry from previous limb
      muladd1(carry, qp_lo, q, M[i], carry)

    block: # a*2^64 - q*p
      var borrow: Borrow
      subB(borrow, a[i], a[i], qp_lo, Borrow(0))
      carry += SecretWord(borrow) # Adjust if borrow

    over_p = mux(
              a[i] == M[i], over_p,
              a[i] > M[i]
            )

  # Fix quotient, the true quotient is either q-1, q or q+1
  #
  # if carry < q or carry == q and over_p we must do "a -= p"
  # if carry > hi (negative result) we must do "a += p"

  result.neg = carry > hi
  result.tooBig = not(result.neg) and (over_p or (carry < hi))

func shlAddMod(a: LimbsViewMut, aLen: int,
               c: SecretWord, M: LimbsViewConst, mBits: int) =
  ## Fused modular left-shift + add
  ## Shift input `a` by a word and add `c` modulo `M`
  ##
  ## With a word W = 2^WordBitWidth and a modulus M
  ## Does a <- a * W + c (mod M)
  ##
  ## The modulus `M` most-significant bit at `mBits` MUST be set.
  if mBits <= WordBitWidth:
    # If M fits in a single limb

    # We normalize M with R so that the MSB is set
    # And normalize (a * 2^64 + c) by R as well to maintain the result
    # This ensures that (a0, a1)/p0 fits in a limb.
    let R = mBits and (WordBitWidth - 1)

    # (hi, lo) = a * 2^64 + c
    let hi = (a[0] shl (WordBitWidth-R)) or (c shr R)
    let lo = c shl (WordBitWidth-R)
    let m0 = M[0] shl (WordBitWidth-R)

    var q, r: SecretWord
    div2n1n(q, r, hi, lo, m0)  # (hi, lo) mod M

    a[0] = r shr (WordBitWidth-R)

  else:
    ## Multiple limbs
    let (neg, tooBig) = shlAddMod_estimate(a, aLen, c, M, mBits)
    discard a.cadd(M, ctl = neg, aLen)
    discard a.csub(M, ctl = tooBig, aLen)

func reduce(r: LimbsViewMut,
            a: LimbsViewAny, aBits: int,
            M: LimbsViewConst, mBits: int) =
  ## Reduce `a` modulo `M` and store the result in `r`
  let aLen = numWordsFromBits(aBits)
  let mLen = numWordsFromBits(mBits)
  let rLen = mLen

  if aBits < mBits:
    # if a uses less bits than the modulus,
    # it is guaranteed < modulus.
    # This relies on the precondition that the modulus uses all declared bits
    copyWords(r, 0, a, 0, aLen)
    for i in aLen ..< mLen:
      r[i] = Zero
  else:
    # a length i at least equal to the modulus.
    # we can copy modulus.limbs-1 words
    # and modular shift-left-add the rest
    let aOffset = aLen - mLen
    copyWords(r, 0, a, aOffset+1, mLen-1)
    r[rLen - 1] = Zero
    # Now shift-left the copied words while adding the new word modulo M
    for i in countdown(aOffset, 0):
      shlAddMod(r, rLen, a[i], M, mBits)

func reduce*[aLen, mLen](r: var Limbs[mLen],
                         a: Limbs[aLen], aBits: static int,
                         M: Limbs[mLen], mBits: static int
                        ) {.inline.} =
  ## Reduce `a` modulo `M` and store the result in `r`
  ##
  ## Warning ⚠: At the moment this is NOT constant-time
  ##            as it relies on hardware division.
  # This is implemented via type-erased indirection to avoid
  # a significant amount of code duplication if instantiated for
  # varying bitwidth.
  reduce(r.view(), a.view(), aBits, M.view(), mBits)

{.pop.} # raises no exceptions
