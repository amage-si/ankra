import Base
import ./main.bend as A

def check(ok: Bool, message: String) -> IO(Unit):
  match ok:
    case True{}: IO.print("PASS " ++ message)
    case False{}: IO.die(Unit, 1, "FAIL " ++ message)

def rejected(result: Result<&1, &1, U32 & String, Window>) -> IO(Unit):
  match result:
    case Fail{(code, message)}:
      check(U32.is_eq(code, 22), "invalid window rejected before allocation")
    case Done{window}:
      do IO<Unit>:
        Window.close(window)
        IO.die(Unit, 1, "invalid dimensions unexpectedly opened a window")

def batch_empty(batch: A.Batch) -> Bool:
  match batch:
    case A.Batch{False{}, 0, Nil{}}: True{}
    case _: False{}

def batch_order(batch: A.Batch) -> Bool:
  match batch:
    case A.Batch{True{}, 4, Move{7, 9} <> Mouse{7, 9, 0, True{}} <> Key{32, False{}} <> Close{} <> Nil{}}:
      True{}
    case _: False{}

def main() -> IO(Unit):
  do IO<Unit>:
    check(batch_empty(A.collect(Nil{})), "empty batch")
    check(batch_order(A.collect([Move{7, 9}, Mouse{7, 9, 0, True{}}, Key{32, False{}}, Close{}])), "event order and close")
    check(A.valid_size(1, 1) && A.valid_size(4096, 4096), "accepted bounds")
    check(Bool.not(A.valid_size(0, 1)) && Bool.not(A.valid_size(1, 4097)), "invalid bounds")
    zero : Result<&1, &1, U32 & String, Window> <- A.open("Ankra invalid", 0, 8)
    rejected(zero)
    big : Result<&1, &1, U32 & String, Window> <- A.open("Ankra invalid", 8, 4097)
    rejected(big)
    IO.print("6 Ankra checks passed")
