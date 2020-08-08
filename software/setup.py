from distutils.core import setup, Extension

module1 = Extension('command',
                    define_macros = [('MAJOR_VERSION', '0'),
                                     ('MINOR_VERSION', '1')],
                    include_dirs = ['/usr/local/include'],
                    libraries = ['m'],
                    library_dirs = ['/usr/local/lib'],
                    sources = ['command.c'])

setup(name = 'PackageName',
       version = '0.1',
       description = 'Control Interface Command Generator',
       author = 'Yuan Mei',
       author_email = 'yuan.mei@gmail.com',
       url = '',
       long_description = '',
       ext_modules = [module1]
)
