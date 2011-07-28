/** Functions for evaluating expressions.

    Authors:    Cristian Cobzarenco
    Copyright:  Copyright (c) 2011, Cristian Cobzarenco. All rights reserved.
    License:    Boost License 1.0
*/
module scid.ops.eval;

public import scid.ops.expression;

import scid.common.traits;
import scid.common.meta;

import scid.ops.fallback;
import scid.ops.common;

import scid.internal.regionallocator;

import scid.matvec;

debug = eval;

debug( eval ) {
	import std.stdio;	
}

/** Evaluate a leaf expression (a floating point type, BasicVector or BasicMatrix) - simply return it. */
auto eval( T )( T value ) if( isLeafExpression!T ) {
	return value;	
}

/** Evaluate a trivial scalar expression. */
auto eval(string op_, Lhs, Rhs)( auto ref Expression!(op_, Lhs, Rhs) expr )
	if( expr.closure   == Closure.Scalar         && (
		expr.operation == Operation.ScalScalSum  ||
		expr.operation == Operation.ScalScalProd ||
		expr.operation == Operation.ScalScalDiv  ||
		expr.operation == Operation.ScalScalSub  ||  
		expr.operation == Operation.ScalScalPow
	)) {
	return mixin("eval( expr.lhs )" ~ op_ ~ "eval( expr.rhs )");
}

/** Evaluate a dot product expression. */
auto eval(string op_, Lhs, Rhs)( auto ref Expression!(op_, Lhs, Rhs) expr )
		if( expr.operation == Operation.DotProd ) {
	return evalDot(expr.lhs, expr.rhs);
}

/** Evaluate a matrix or vector expression. */
ExpressionResult!E  eval( E )( auto ref E expr ) if( isExpression!E && E.closure != Closure.Scalar ) {
	// ExpressionResult gives you the type required to save the result of an expression.
	typeof(return) result;
	evalCopy( expr, result );
	return result;
}


/** Evaluate a matrix or vector expression in memory allocated with the specified allocator. */
auto eval( E, Allocator )( auto ref E expr, Allocator* allocator )
		if( isAllocator!Allocator && isExpression!E && E.closure != Closure.Scalar ) {
	// ExpressionResult gives you the type required to save the result of an expression.
	static if( isVectorClosure!(E.closure) ) {
		debug( eval ) writeln("Allocated temporary of size ", expr.length, ".");
		auto result = (ExpressionResult!E).Temporary( expr.length, allocator );
	} else {
		debug( eval ) writeln("Allocated temporary of size (", expr.rows,", ", expr.columns, ").");
		auto result = (ExpressionResult!E).Temporary( expr.rows, expr.columns, allocator );
	}
	evalCopy( expr, result );
	return result;
}

/** Scale destination with a scalar expression. */
void evalScaling( Scalar, Dest )( auto ref Scalar scalar, auto ref Dest dest ) {
	alias BaseElementType!Dest T;
	alias closureOf!Dest closure;
	
	static assert( is( T : BaseElementType!Scalar ),
		"Types in " ~ to!string(closure) ~ "-Scalar multiplication do not match (" ~
		T.stringof ~ " and " ~ (BaseElementType!Scalar).stringof ~ ")."
	);
	
	static assert( closureOf!Scalar == Closure.Scalar,
		"Cannot perform " ~ to!string(closure) ~ "-" ~ to!string(closureOf!Scalar) ~
		"multiplication in place."
	);
	
	static if( __traits( compiles, dest.storage.scale( scalar ) ) ) {
		// custom expression scaling
		dest.storage.scale( scalar );
	} else static if( __traits( compiles, dest.storage.scale( eval(scalar) ) ) ) {
		// custom literal scaling
		dest.storage.scale( eval(scalar) );
	} else {
		fallbackScaling( eval(scalar), dest );	
	}
		
}

/** Copy the result of the source expression into the destination. */
void evalCopy( Transpose tr = Transpose.no, Source, Dest )( auto ref Source source, auto ref Dest dest ) {
	alias BaseElementType!Source                  T;
	alias transposeClosure!(closureOf!Source, tr) srcClosure;
	alias closureOf!Dest                          dstClosure;
	
	// check correct operation
	static assert( isLeafExpression!Dest, Dest.stringof ~ " is not a lvalue." );
	
	static assert( is( T : BaseElementType!Dest ),
		"Types in assignment do not have the same element type (" ~
		T.stringof ~ " and " ~ (BaseElementType!Dest).stringof ~ ")."
	);
	
	static assert( srcClosure == dstClosure,
		"Incompatible types for assignment '" ~ to!string(srcClosure) ~
		"' and '" ~ to!string(dstClosure) ~ "'."
	);
	
	void resizeDest() {
		static if( srcClosure == Closure.Matrix )
			// matrix resizing
			dest.storage.resize( source.rows, source.columns );
		else
			// vector resizing
			dest.storage.resize( source.length );
	}

	static if( __traits( compiles, dest.storage.copy!tr( source.storage ) ) ) {
		// call custom copy routine on destination
		dest.storage.copy!tr( source.storage );
	} else static if( __traits( compiles, source.storage.copyRight!tr( dest.storage ) ) ) {
		// call custom copy routine on source
		source.storage.copyRight!tr( dest.storage );
	} else static if( isExpression!Source ) {
		enum op = Source.operation;
		static if( isScaling!op ) {
			// copy from a scaling operation - clear the destination & axpy with 1*source
			resizeDest();
			evalScaledAddition!tr( source.rhs, source.lhs, dest );
		} else static if( isAddition!op ) {
			// copy from an addition - copy the first operand and axpy with the second
			evalCopy!tr( source.lhs, dest );
			evalScaledAddition!tr( One!T, source.rhs, dest );
		} else static if( isTransposition!op ) {
			// copy from a transposition operation - recurse with the negated tranposition flag
			evalCopy!( transNot!tr )( source.lhs, dest );
		} else static if( op == Operation.MatMatProd ) {
			// copy from a matrix multiplication - fwd to hlMatMult
			static if( tr )
				evalMatrixProduct!( Transpose.yes, Transpose.yes )( One!T, source.rhs, source.lhs, Zero!T, dest );
			else
				evalMatrixProduct!( Transpose.no, Transpose.no )( One!T, source.lhs, source.rhs, Zero!T, dest );
		} else static if( op == Operation.RowMatProd ) {
			evalMatrixVectorProduct!( Transpose.yes, Transpose.yes )( One!T, source.rhs, source.lhs, Zero!T, dest );
		} else static if( op == Operation.MatColProd ) {
			evalMatrixVectorProduct!( Transpose.no, Transpose.no )( One!T, source.lhs, source.rhs, Zero!T, dest );
		} else { 
			// can't solve the expression - use a temporary by calling eval
			RegionAllocator alloc = newRegionAllocator();
			evalCopy!tr( eval(source, &alloc), dest );
		}
	} else {
		resizeDest();
		fallbackCopy!tr( source, dest );
	}
		
}

/** Scale the source expression with a scalar expression and add it to the destination. */
void evalScaledAddition( Transpose tr = Transpose.no, Scalar, Source, Dest )( auto ref Scalar alpha, auto ref Source source, auto ref Dest dest ) {
	alias BaseElementType!Source                  T;
	alias transposeClosure!(closureOf!Source, tr) srcClosure;
	alias closureOf!Dest                          dstClosure;
	enum multClosure = closureOf!(operationOf!("*",srcClosure,closureOf!Scalar));
	
	// check correct operation
	static assert( isLeafExpression!Dest, Dest.stringof ~ " is not an lvalue." );
	static assert( is( T : BaseElementType!Scalar ),
		"Types in " ~ to!string(srcClosure) ~ "-Scalar multiplication do not match (" ~
		T.stringof ~ " and " ~ (BaseElementType!Scalar).stringof ~ ")."
	);
	
	static assert( is( T : BaseElementType!Dest ),
		"Types in addition do not have the same element type (" ~
		T.stringof ~ " and " ~ (BaseElementType!Dest).stringof ~ ")."
	);
	
	static assert( multClosure == dstClosure,
		"Incompatible types for addition '" ~ to!string(multClosure) ~
		"' and '" ~ to!string(dstClosure) ~ "'."
	);
	
	static assert( closureOf!Scalar == Closure.Scalar,
		"Cannot perform " ~ to!string(closure) ~ "-" ~ to!string(closureOf!Scalar) ~
		"multiplication in place."
	);
	
	static if( __traits( compiles, dest.storage.scaledAddition( alpha, source.storage ) ) ) {
		dest.storage.scaledAddition( alpha, source.storage );
	} else static if( __traits( compiles, source.storage.scaledAdditionRight( alpha, dest.storage ) ) ) {
		source.storage.scaledAdditionRight( alpha, dest.storage );
	} else static if( __traits( compiles, dest.storage.scaledAddition( eval( alpha ), source.storage ) ) ) {
		dest.storage.scaledAddition( eval( alpha ), source.storage );
	} else static if( __traits( compiles, source.storage.scaledAdditionRight( eval( alpha ), dest.storage ) ) ) {
		source.storage.scaledAdditionRight( eval( alpha ), dest.storage );
	} else static if( isExpression!Source ) {
		enum op = Source.operation;
		static if( isScaling!op ) {
			// axpy with a scaling operation - multiply alpha by the scalar
			evalScaledAddition!tr( alpha * source.rhs, source.lhs, dest );
		} else static if( isAddition!op ) {
			// axpy with an addition - distribute the scalar between the operands
			evalScaledAddition!tr( alpha, source.lhs, dest );
			evalScaledAddition!tr( alpha, source.rhs, dest );
		} else static if( isTransposition!op ) {
			// axpy with transposition - recurse with the transposition flag negated
			evalScaledAddition!( transNot!tr )( alpha, source.lhs, dest );
		} else static if( op == Operation.MatMatProd ) {
			// axpy from a matrix multiplication - fwd to hlMatMult
			static if( tr )
				evalMatrixProduct!( Transpose.yes, Transpose.yes )( One!T, source.rhs, source.lhs, One!T, dest );
			else
				evalMatrixProduct!( Transpose.no, Transpose.no )( One!T, source.lhs, source.rhs, One!T, dest );
		} else static if( op == Operation.RowMatProd ) {
			evalMatrixVectorProduct!( transNot!tr, transNot!tr )( One!T, source.rhs, source.lhs, One!T, dest );
		} else static if( op == Operation.MatColProd ) {
			evalMatrixVectorProduct!( tr, tr )( One!T, source.lhs, source.rhs, One!T, dest );
		} else {
			// if we can't solve the expression then use a temporary by calling eval
			RegionAllocator alloc = newRegionAllocator();
			evalScaledAddition!tr( alpha, eval(source, &alloc), dest );
		}
	} else
		fallbackScaledAddition!tr( alpha, source, dest );
}

/** Copy the product of two matrices into the destination matrix. */
void evalMatrixProduct( Transpose transA = Transpose.no, Transpose transB = Transpose.no, Alpha, Beta, A, B, Dest )
		( auto ref Alpha alpha, auto ref A a, auto ref B b, auto ref Beta beta, auto ref Dest dest ) {
	alias BaseElementType!Dest T;
	
	static assert( isLeafExpression!Dest, Dest.stringof ~ " is not an lvalue." );
	static assert( is( T : BaseElementType!Alpha ) && is( T : BaseElementType!Beta ) && is( T : BaseElementType!A ) && is( T : BaseElementType!B ) );
	static assert( closureOf!A == Closure.Matrix && closureOf!B == Closure.Matrix && closureOf!Alpha == Closure.Scalar && closureOf!Beta == Closure.Scalar );
	
	static if( __traits( compiles, dest.storage.matrixProduct( alpha, a.storage, b.storage, beta ) ) ) {
		dest.storage.matrixProduct( alpha, a.storage, b.storage, beta );
	} else static if( __traits( compiles, dest.storage.matrixProduct( eval(alpha), a.storage, b.storage, eval(beta) ) ) ) {
		auto alphaValue = eval( alpha );
		auto betaValue  = eval( beta  );
		dest.storage.matrixProduct( alphaValue, a.storage, b.storage, betaValue );
	} else static if( isExpression!A ) {
		static if( A.operation == Operation.MatScalProd ) {
			evalMatrixProduct!(transA,transB)( alpha * a.rhs, a.lhs, b, beta, dest ); 
		} else static if( A.operation == Operation.MatTrans ) {
			evalMatrixProduct!( transNot!transA, transB )( alpha, a.lhs, b, beta, dest );
		} else static if( A.operation == Operation.MatInverse ) {
			auto betaValue = eval( beta );
			if( !betaValue ) {
				// dest = vec * alpha; dest = inv(mat.lhs) * dest
				evalCopy!transB( b * alpha, dest );
				evalSolve!transA( a.lhs, dest );
			} else {
				static if( transB )
					auto tmp = eval( b.t * alpha );
				else
					auto tmp = eval( b * alpha );
				evalSolve!transM( a, tmp );
				evalScaling( beta, dest );
				evalScaledAddition( alpha, tmp, dest );
			}
		} else {
			RegionAllocator alloc = newRegionAllocator();			
			evalMatrixProduct!( transA, transB )( alpha, eval(a, &alloc), b, beta, dest );
		}
	} else static if( isExpression!B ) {
		static if( B.operation == Operation.MatScalProd ) {
			evalMatrixProduct!( transA, transB )( alpha * b.rhs, a, b.lhs, beta, dest ); 
		} else static if( B.operation == Operation.MatTrans ) {
			evalMatrixProduct!( transA, transNot!transB )( alpha, a, b.lhs, beta, dest );
		} else {
			RegionAllocator alloc = newRegionAllocator();
			evalMatrixProduct!( transA, transB )( alpha, a, eval(b, &alloc), beta, dest );
		}
	} else {
		auto vAlpha = eval( alpha );
		auto vBeta  = eval( beta  );
		fallbackMatrixProduct!(transA,transB)( vAlpha, a, b, vBeta, dest );
	}
}

/** Copy the result of a matrix-vector product between expressions into the destination. */
void evalMatrixVectorProduct( Transpose transM, Transpose transV, Alpha, Beta, Mat, Vec, Dest )
		( auto ref Alpha alpha, auto ref Mat mat, auto ref Vec vec, auto ref Beta beta, auto ref Dest dest ) {
	enum vecClosure = transposeClosure!( Vec.closure, transV );
	alias BaseElementType!Alpha T;
	
	static assert( vecClosure       == Closure.ColumnVector );
	static assert( closureOf!Alpha  == Closure.Scalar );
	static assert( closureOf!Beta   == Closure.Scalar );
	static assert( closureOf!Mat    == Closure.Matrix );
	static assert( is( BaseElementType!Dest : T ) );
	static assert( is( BaseElementType!Mat  : T ) );
	static assert( is( BaseElementType!Vec  : T ) );
	static assert( is( BaseElementType!Beta : T ) );
	static assert( isLeafExpression!Dest );
	
	static if( __traits( compiles, mat.storage.matrixVectorProduct!(transM,transV)( alpha, vec.storage, beta, dest ) ) ) {
		mat.storage.matrixVectorProduct!(transM,transV)( alpha, vec.storage, beta, dest );
	} else static if( __traits( compiles, mat.storage.mv!(transM,transV)( eval( alpha ), vec.storage, eval(beta), dest ) ) ) {
		mat.storage.matrixVectorProduct!(transM,transV)( eval( alpha ), vec.storage, eval(beta), dest );
	} else static if( __traits( compiles, dest.storage.matrixVectorProductRight!(transM,transV)( alpha, mat.storage, vec.storage, eval( beta ) ) ) ) {
		dest.storage.matrixVectorProductRight!(transM,transV)( alpha, mat.storage, vec.storage, eval( beta ) );
	} else static if( __traits( compiles, dest.storage.matrixVectorProductRight!(transM,transV)( eval( alpha ), mat.storage, vec.storage, eval( beta ) ) ) ) {
		dest.storage.matrixVectorProductRight!(transM,transV)( eval( alpha ), mat.storage, vec.storage, eval( beta ) );
	} else static if( isExpression!Vec ) {
		static if( Vec.operation == Operation.RowScalProd || Vec.operation == Operation.ColScalProd ) {
			evalMatrixVectorProduct!( transM, transV )( alpha * vec.rhs, mat, vec.lhs, beta, dest );
		} else static if ( Vec.operation == Operation.RowTrans || Vec.operation == Operation.ColTrans ) {
			evalMatrixVectorProduct!( transM, transNot!transV )( alpha, mat, vec.lhs, beta, dest );
		} else {
			RegionAllocator alloc = newRegionAllocator();
			evalMatrixVectorProduct!( transM, transV )( alpha, mat, eval(vec,&alloc), beta, dest );
		}
	} else static if( isExpression!Mat ) {
		static if( Mat.operation == Operation.MatScalProd ) {
			evalMatrixVectorProduct!( transM, transV )( alpha * mat.rhs, mat.lhs, vec, beta, dest );
		} else static if( Mat.operation == Operation.MatTrans ) {
			evalMatrixVectorProduct!( transNot!transM, transV )( alpha, mat.lhs, vec, beta, dest );
		} else static if( Mat.operation == Operation.MatInverse ) {
			// d = inv(A) * v
			auto betaValue = eval( beta );
			if( !betaValue ) {
				// dest = vec * alpha; dest = inv(mat.lhs) * dest
				evalCopy!transV( vec * alpha, dest );
				evalSolve!transM( mat.lhs, dest );
			} else {
				static if( transV )
					auto tmp = eval( vec.t * alpha );
				else
					auto tmp = eval( vec * alpha );
				evalSolve!transM( mat, tmp );
				evalScaling( beta, dest );
				evalScaledAddition( alpha, tmp, dest );
			}
		} else {
			RegionAllocator alloc = newRegionAllocator();
			evalMatrixVectorProduct!( transM, transV )( alpha, eval(mat, &alloc), vec, beta, dest );	
		}
	} else {
		auto vAlpha = eval( alpha );
		auto vBeta  = eval( beta );
		fallbackMatrixVectorProduct!(transM, transV)( vAlpha, mat, vec, vBeta, dest );
	}
}

/** Solve linear system (D := M^^(-1) * D). */
void evalSolve( Transpose transM = Transpose.no, Mat, Dest )( auto ref Mat mat, auto ref Dest dest ) {
	alias BaseElementType!Mat T;
	
	static assert( isLeafExpression!Dest );
	
	static if( __traits( compiles, dest.storage.solve!transM( mat.storage ) ) ) {
		dest.storage.solve!transM( dest.storage );
	} else static if( isLeafExpression!Mat || __traits( compiles, mat.storage.solveRight!transM( dest.storage ) ) ) {
		mat.storage.solveRight!transM( dest.storage );
	} else static if( isExpression!Mat ) {
		static if( Mat.operation == Operation.MatScalProd ) {
			// inv(x*A)*D = inv(A) * (D / x)
			evalScal( One!T / mat.rhs, dest );
			evalSolve!transM( mat.lhs, dest );
		} else static if( Mat.operation == Operation.MatTrans ) {
			// inv(A.t) * D
			evalSolve!(transNot!transM)( mat.lhs, dest );
		} else static if( Mat.operation == Operation.MatMatProd ) {
			static if( !transM ) {
				// inv(A*B) * D = inv(B) * (inv(A) * D);
				evalSolve( mat.lhs, dest );
				evalSolve( mat.rhs, dest );
			} else {
				// inv(A*B).t * D = inv(A).t * (inv(B).t * D);
				evalSolve!transM( mat.rhs, dest );
				evalSolve!transM( mat.lhs, dest );
			}
		} else {
			RegionAllocator alloc = newRegionAllocator();
			evalSolve!transM( eval(mat, &alloc), dest );
		}
	} else {
		fallbackSolve!transM( mat, dest );
	}
}

/** Return the dot product of two vector expressions. */
auto evalDot( Transpose transA = Transpose.no, Transpose transB = Transpose.no, A, B )( auto ref A a, auto ref B b ) {
	alias BaseElementType!A T;
	enum aClosure = transposeClosure!(closureOf!A, transA);
	enum bClosure = transposeClosure!(closureOf!B, transB);
		
	static assert( aClosure == Closure.RowVector );
	static assert( bClosure == Closure.ColumnVector );
	
	static if( __traits( compiles, a.storage.dot!( transXor!(transA,transB) )( b.storage ) ) ) {
		auto r = a.storage.dot!( transXor!(transA,transB) )( b.storage );
		static if( transB && isComplex!T )
			return gconj( r );
		else
			return r;
	} else static if( __traits( compiles, b.storage.dot!( transXor!(transA,transB) )( a.storage ) ) ) {
		auto r = b.storage.dot!( transXor!(transA,transB) )( a.storage );
		static if( transA && isComplex!T )
			return gconj( r );
		else
			return r;
	} else static if( isExpression!A ) {
		static if( A.operation == Operation.RowScalProd || A.operation == Operation.ColScalProd ) {
			return evalDot!(transA,transB)(a.lhs, b) * a.rhs;
		} else static if( A.operation == Operation.RowTrans || A.operation == Operation.ColTrans ) {
			return evalDot!( transNot!transA, transB )( a.lhs, b );
		}  else {
			RegionAllocator alloc = newRegionAllocator();
			return evalDot!(transA,transB)( eval( a, &alloc ), b );
		}
	} else static if( isExpression!B ) {
		return evalDot!(transNot!transB,transNot!transA)( b, a );
	} else {
		auto r = fallbackDot!(transA, transB)( a, b );
		return r;
	}
}

template isPrimitiveLiteral( T ) {
    enum isPrimitiveLiteral = (is( T : BaseElementType!T[] ) || is( T : BaseElementType!T[][] ) || is( T : BaseElementType!T )) && isFortranType!(BaseElementType!T);
}

template StorageOf( T ) {
    static if( isPrimitiveLiteral!T )
        alias T StorageOf;
    else
        alias T.Storage StorageOf;
}

