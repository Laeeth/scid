/** Implementation of the CowMatrix container, a copy-on-write matrix which is the default container for matrix storage
    types.

    Authors:    Cristian Cobzarenco
    Copyright:  Copyright (c) 2011, Cristian Cobzarenco. All rights reserved.
    License:    Boost License 1.0
*/
module scid.storage.cowmatrix;

import scid.matrix;
import scid.blas;

import scid.ops.common;
import scid.ops.expression;

import scid.storage.arraydata;
import scid.storage.cowarray;
import scid.common.meta;
import scid.common.storagetraits;

import scid.internal.assertmessages;

import std.algorithm, std.typecons;
import std.array, std.conv;


/** A copy-on-write matrix. Used as a container for storage types. */
struct CowMatrix( ElementType_, StorageOrder storageOrder_ = StorageOrder.ColumnMajor ) {
	alias ElementType_                                                 ElementType;
	alias ArrayData!ElementType                                        Data;
	alias storageOrder_                                                storageOrder;
	alias CowMatrix!(ElementType, transposeStorageOrder!storageOrder ) Transposed;
	alias CowArrayRef!ElementType                                      ArrayType;
	
	enum isRowMajor = (storageOrder == StorageOrder.RowMajor);
	
	/** Allocate a new matrix of given dimensions. Initialize with zero. */
	this()( size_t newRows, size_t newCols ) {
		if( newRows != 0 && newCols != 0 ) {
			data_.reset( newRows * newCols );
			ptr_     = data_.ptr;
			rows_    = newRows;
			cols_    = newCols;
			leading_ = minor_;
			blas.scal( newRows * newCols, Zero!ElementType, ptr_, 1 );
		}
	}
	
	/** Allocate a new uninitialized matrix of given dimensions. */
	this()( size_t newRows, size_t newCols, void* ) {
		if( newRows != 0 && newCols != 0 ) {
			data_.reset( newRows * newCols );
			ptr_     = data_.ptr;
			rows_    = newRows;
			cols_    = newCols;
			leading_ = minor_;
		}
	}
	
	/** Create a new matrix with a given major dimension (i.e number of columns for ColumnMajor matrices)
	    and an array with the elements in minor order.
	*/
	this( E )( size_t newMajor, E[] initializer ) if( isConvertible!(E, ElementType) )
	in {
		checkGeneralInitializer_( newMajor, initializer );
	} body {
		if( !initializer.length )
			return;
		
		data_.reset( to!(ElementType[])(initializer) );
		ptr_     = data_.ptr;
		major_   = newMajor;
		minor_   = initializer.length / major_;
		leading_ = minor_;
	}
	
	this( E )( E[][] initializer ) if( isConvertible!(E, ElementType) )
	in {
		checkGeneralInitializer_( initializer );
	} body {
		if( initializer.length == 0 || initializer[0].length == 0 )
			return;
		
		rows_ = initializer.length;
		cols_ = initializer[0].length;
		data_.reset( rows_ * cols_ );
		
		ptr_     = data_.ptr;
		leading_ = minor_;
		
		foreach( i ; 0 .. rows )
			foreach( j ; 0.. columns )
				indexAssign( to!ElementType(initializer[i][j]), i, j );
	}
	
	/** Create a matrix as a copy of another exisiting one. */
	this()( CowMatrix* other ) {
		data_    = other.data_;
		ptr_     = other.ptr_;
		rows_    = other.rows_;
		cols_    = other.cols_;
		leading_ = other.leading_;
	}
	
	/** Create a matrix as a copy of another exisiting one. */
	this()( Transposed* other ) {
		data_    = other.data_;
		ptr_     = other.ptr_;
		rows_    = other.cols_;
		cols_    = other.rows_;
		leading_ = other.leading_;
	}
	
	/** Create a matrix as a slice of an existing one. */
	this()( CowMatrix* other, size_t rowStart, size_t numRows, size_t colStart, size_t numCols ) {
		data_    = other.data_;
		rows_    = numRows;
		cols_    = numCols;
		leading_ = other.leading_;
		ptr_     = other.ptr_ + mapIndex(rowStart, colStart);
	}
	
	/// ditto
	this()( CowMatrix* other, size_t firstIndex, size_t numRows, size_t numCols )
	in {
		
	} body {
		data_    = other.data_;
		rows_    = numRows;
		cols_    = numCols;
		leading_ = other.leading_;
		ptr_     = other.ptr_ + firstIndex;
	}
	
	/** Resize the matrix and set all the elements to zero. */
	void resize( size_t newRows, size_t newCols ) {
		resize( newRows, newCols, null );
		if( !empty )
			generalMatrixScaling!storageOrder( rows_, cols_, Zero!ElementType, ptr_, leading_ );
	}
	
	/** Resize the matrix and leave the elements uninitialized. */
	void resize( size_t newRows, size_t newCols, void* ) {
		auto newLength = newRows * newCols;
		if( newLength != data_.length || data_.refCount() > 1 ) {
			data_.reset( newLength );

			if( newLength != 0 ) {
				rows_    = newRows;
				cols_    = newCols;
				leading_ = minor_;
				ptr_     = data_.ptr;
			} else {
				clear_();
			}
		}
	}
	
	/** Assignment has copy semantics. The actual copy is only performed on modification of the copy however. */
	ref typeof( this ) opAssign( CowMatrix rhs ) {
		swap( data_,  rhs.data_ );
		ptr_     = rhs.ptr_;
		rows_    = rhs.rows_;
		cols_    = rhs.cols_;
		leading_ = rhs.leading_;
		
		return this;
	}
	
	/** Element access. */
	ElementType index( size_t i, size_t j ) const
	in {
		checkBounds_( i, j );
	} body {
		return ptr_[ mapIndex( i, j ) ];
	}
	
	/// ditto
	void indexAssign( string op = "" )( ElementType rhs, size_t i, size_t j )
	in {
		checkBounds_( i, j );
	} out {
		assert( data_.refCount() == 1 );
	} body {
		unshareData_();
		mixin( "ptr_[ mapIndex( i, j ) ]" ~ op ~ "= rhs;" );
	}
	
	/** Remove the first major subvector (e.g. column for column major matrices). Part of the BidirectionalRange
	    concept.
	*/
	void popFront()
	in {
		checkNotEmpty_!"popFront"();
	} body {
		if( -- major_ )
			ptr_ += leading_;
		else
			clear_();
	}
	
	/** Remove the last major subvector (e.g. column for column major matrices). Part of the BidirectionalRange
	    concept.
	*/
	void popBack()
	in {
		checkNotEmpty_!"popBack"();
	} body {
		if( ( -- major_ ) == 0 )
			clear_();
	}
	
	@property {
		/** Get a const pointer to the memory used by this storage. */
		const(ElementType*) cdata() const {
			return ptr_;
		}
		
		/** Get a mutable pointer to the memory used by this storage. */
		ElementType* data() {
			unshareData_();
			return ptr_;
		}
		
		/** Returh the length of the range (number of major subvectors). Part of the BidirectionalRange concept. */
		size_t length() const {
			return major_;
		}
		
		/** Is the array empty? Part of the BidirectionalRange concept. */
		bool empty() const {
			return major_ == 0;
		}
		
		/** Get the leading dimesnion of the matrix. */
		size_t leading() const {
			return leading_;
		}
		
		/** Get the number of rows. */
		size_t rows() const {
			return rows_;
		}
		
		/** Get the number of columns. */
		size_t columns() const {
			return cols_;
		}
		
		/** Get the number of major subvectors. */
		size_t major() const { 
			return major_;
		}
		
		/** Get the number of minor subvectors. */
		size_t minor() const {
			return minor_;
		}
		
		/** Get the address of this. Needed for a hack to avoid copying in certain cases. */
		typeof(this)* ptr() {
			return &this;
		}
	}
	
	size_t mapIndex( size_t i, size_t j ) const {
		if( isRowMajor )
			return i * leading_ + j;
		else
			return j * leading_ + i;
	}
	
	/** Promotions for this type. */
	template Promote( T ) {
		static if( isArrayContainer!T )
			// TODO: Implement some kind of rebind for containers
			alias CowArrayRef!(Promotion!(BaseElementType!T,ElementType)) Promote;
		else static if( isMatrixContainer!T ) {
			alias CowMatrixRef!(Promotion!(BaseElementType!T,ElementType)) Promote;
		} else static if( isScalar!T ) {
			alias CowMatrixRef!(Promotion!(T,ElementType)) Promote;
		}
	}
	
private:
	mixin MatrixChecks;

	static if( isRowMajor ) {
		alias rows_ major_;
		alias cols_ minor_;
	} else {
		alias rows_ minor_;
		alias cols_ major_;
	}
	
	void clear_() {
		// This is OK, right?
		clear( this );
	}
	
	void unshareData_() {
		// The < 2 is because refCount() == 0 is when the matrix is empty
		if( data_.refCount() < 2 )
			return;
		
		if( leading_ == minor_ ) {
			auto len = rows_ * cols_;
			if( ptr_ == data_.ptr && len == data_.length )
				data_.unshare();
			else
				data_.reset( ptr_[ 0 .. len ] );
		} else {
			auto oldp = ptr_; // save the old ptr
			
			// NOTE: oldp won't be invalidated, because we know data_ is shared.
			data_.reset( rows_ * cols_ );
			auto newp = data_.ptr;
			
			blas.xgecopy!'N'(rows_, cols_, oldp, leading_, newp, minor_ );

			leading_ = minor_;
		}
		
		ptr_ = data_.ptr;
	}
	
	size_t        leading_ = 1;  // BLAS/LAPACK require leading_ >= 1 all the time
	size_t        rows_, cols_;
	Data          data_;
	ElementType*  ptr_;
}

/** A simple alias for the preferred reference type for this container. */
template CowMatrixRef( T, StorageOrder order_ = StorageOrder.ColumnMajor ) {
	alias RefCounted!(CowMatrix!(T,order_), RefCountedAutoInitialize.yes )
			CowMatrixRef;
}

unittest {
	// TODO: CowArray tests.
}
