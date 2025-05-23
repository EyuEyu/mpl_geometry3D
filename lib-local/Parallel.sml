structure Parallel:
sig
  val parfor: int * int -> (int -> unit) -> unit

  val parforg: int -> int * int -> (int -> unit) -> unit

  val tabulate: (int * int) -> (int -> 'a) -> 'a Seq.t

  val reduce: ('a * 'a -> 'a) -> 'a -> (int * int) -> (int -> 'a) -> 'a

  val scan: ('a * 'a -> 'a)
            -> 'a
            -> (int * int)
            -> (int -> 'a)
            -> 'a Seq.t (* length N+1, for both inclusive and exclusive scan *)

  val filter: (int * int) -> (int -> 'a) -> (int -> bool) -> 'a Seq.t

  val tabFilter: (int * int) -> (int -> 'a option) -> 'a Seq.t
end =
struct

  structure A = Array
  structure AS = ArraySlice

  val w2i = Word64.toIntX
  val i2w = Word64.fromInt


  val grain = 4
  val block_size = 100


  fun for (wlo, whi) f =
    if wlo >= whi then () else (f (w2i wlo); for (wlo + 0w1, whi) f)


  fun parfor (lo, hi) f =
    let
      val wgrain = i2w grain

      fun loopCheck lo hi =
        if hi - lo <= wgrain then for (lo, hi) f else loopSplit lo hi

      and loopSplit lo hi =
        let
          val half = Word64.>> (hi - lo, 0w1)
          val mid = lo + half
        in
          ForkJoin.par (fn _ => loopCheck lo mid, fn _ => loopCheck mid hi);
          ()
        end
    in
      if hi - lo <= grain then Util.for (lo, hi) f
      else loopSplit (i2w lo) (i2w hi)
    end
  
  fun parforg g (lo, hi) f =
    let
      val wgrain = i2w g

      fun loopCheck lo hi =
        if hi - lo <= wgrain then for (lo, hi) f else loopSplit lo hi

      and loopSplit lo hi =
        let
          val half = Word64.>> (hi - lo, 0w1)
          val mid = lo + half
        in
          ForkJoin.par (fn _ => loopCheck lo mid, fn _ => loopCheck mid hi);
          ()
        end
    in
      if hi - lo <= g then Util.for (lo, hi) f
      else loopSplit (i2w lo) (i2w hi)
    end


  fun upd a i x = A.update (a, i, x)
  fun nth a i = A.sub (a, i)


  val par = ForkJoin.par
  val allocate = ForkJoin.alloc


  fun tabulate_ (lo, hi) f =
    let
      val n = hi - lo
      val result = allocate n
    in
      if lo = 0 then parfor (0, n) (fn i => upd result i (f i))
      else parfor (0, n) (fn i => upd result i (f (lo + i)));

      result
    end


  fun foldl g b (lo, hi) f =
    if lo >= hi then b
    else let val b' = g (b, f lo) in foldl g b' (lo + 1, hi) f end


  fun foldr g b (lo, hi) f =
    if lo >= hi then
      b
    else
      let
        val hi' = hi - 1
        val b' = g (b, f hi')
      in
        foldr g b' (lo, hi') f
      end


  fun reduce g b (lo, hi) f =
    let
      val wgrain = i2w grain

      fun loopCheck lo hi =
        if hi - lo <= wgrain then foldl g (f (w2i lo)) (1 + w2i lo, w2i hi) f
        else loopSplit lo hi

      and loopSplit lo hi =
        let
          val half = Word64.>> (hi - lo, 0w1)
          val mid = lo + half
        in
          g (ForkJoin.par (fn _ => loopCheck lo mid, fn _ => loopCheck mid hi))
        end
    in
      if hi - lo <= 0 then b
      else if hi - lo <= grain then foldl g (f lo) (lo + 1, hi) f
      else loopSplit (i2w lo) (i2w hi)
    end


  fun scan_ g b (lo, hi) (f: int -> 'a) =
    if hi - lo <= block_size then
      let
        val n = hi - lo
        val result = allocate (n + 1)
        fun bump ((j, b), x) =
          (upd result j b; (j + 1, g (b, x)))
        val (_, total) = foldl bump (0, b) (lo, hi) f
      in
        upd result n total;
        result
      end
    else
      let
        val n = hi - lo
        val k = block_size
        val m = 1 + (n - 1) div k (* number of blocks *)
        val sums = tabulate_ (0, m) (fn i =>
          let val start = lo + i * k
          in reduce g b (start, Int.min (start + k, hi)) f
          end)
        val partials = scan_ g b (0, m) (nth sums)
        val result = allocate (n + 1)
      in
        parfor (0, m) (fn i =>
          let
            fun bump ((j, b), x) =
              (upd result j b; (j + 1, g (b, x)))
            val start = lo + i * k
          in
            foldl bump (i * k, nth partials i) (start, Int.min (start + k, hi))
              f;
            ()
          end);
        upd result n (nth partials m);
        result
      end


  fun filter_ (lo, hi) f g =
    let
      val n = hi - lo
      val k = block_size
      val m = 1 + (n - 1) div k (* number of blocks *)
      val counts = tabulate_ (0, m) (fn i =>
        let
          val start = lo + i * k
        in
          reduce op+ 0 (start, Int.min (start + k, hi)) (fn j =>
            if g j then 1 else 0)
        end)
      val offsets = scan_ op+ 0 (0, m) (nth counts)
      val result = allocate (nth offsets m)
      fun filterSeq (i, j) c =
        if i >= j then ()
        else if g i then (upd result c (f i); filterSeq (i + 1, j) (c + 1))
        else filterSeq (i + 1, j) c
    in
      parfor (0, m) (fn i =>
        let val start = lo + i * k
        in filterSeq (start, Int.min (start + k, hi)) (nth offsets i)
        end);
      result
    end


  fun tabFilter_ (lo, hi) (f: int -> 'a option) =
    let
      val n = hi - lo
      val k = block_size
      val m = 1 + (n - 1) div k (* number of blocks *)
      val tmp = allocate n

      fun filterSeq (i, j, k) =
        if (i >= j) then
          k
        else
          case f i of
            NONE => filterSeq (i + 1, j, k)
          | SOME v => (A.update (tmp, k, v); filterSeq (i + 1, j, k + 1))

      val counts = tabulate_ (0, m) (fn i =>
        let
          val last = filterSeq
            (lo + i * k, lo + Int.min ((i + 1) * k, n), i * k)
        in
          last - i * k
        end)

      val outOff = scan_ op+ 0 (0, m) (fn i => A.sub (counts, i))
      val outSize = A.sub (outOff, m)

      val result = allocate outSize
    in
      parfor (0, m) (fn i =>
        let
          val soff = i * k
          val doff = A.sub (outOff, i)
          val size = A.sub (outOff, i + 1) - doff
        in
          parfor (0, size) (fn j =>
            A.update (result, doff + j, A.sub (tmp, soff + j)))
        end);
      result
    end


  fun tabulate (lo, hi) f =
    ArraySlice.full (tabulate_ (lo, hi) f)
  fun scan g z (lo, hi) f =
    ArraySlice.full (scan_ g z (lo, hi) f)
  fun filter (lo, hi) f g =
    ArraySlice.full (filter_ (lo, hi) f g)
  fun tabFilter (lo, hi) f =
    ArraySlice.full (tabFilter_ (lo, hi) f)


end
