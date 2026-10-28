// Upstream CatalogActivity.kt, except setContent goes straight to the Material 3 catalog
// (upstream first shows a Material/Material 3 picker that pulls in the whole M2 catalog).
package androidx.compose.material.catalog

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.catalog.library.Material3CatalogApp
import androidx.compose.material3.catalog.library.data.UserPreferencesRepository
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

class CatalogActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        lifecycleScope.launch {
            val repository = UserPreferencesRepository(this@CatalogActivity)
            val favoriteRoute = repository.getFavoriteRoute()
            val theme = repository.getTheme()
            setContent { Material3CatalogApp(initialFavoriteRoute = favoriteRoute, initialTheme = theme) }
        }
    }
}
